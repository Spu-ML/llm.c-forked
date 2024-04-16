#define TESTING
#include "train_gpt2.cu"

// poor man's tensor checker
int check_tensor(float *a, float *b, int n, const char* label) {
    int print_upto = 5;
    int ok = 1;
    printf("%s\n", label);
    for (int i = 0; i < n; i++) {
        if (fabsf(a[i] - b[i]) <= 1e-2) {
            if (i < print_upto) { printf("OK "); }
        } else {
            if (i < print_upto) { printf("NOT OK "); }
            ok = 0;
        }
        if (i < print_upto) { printf("%f %f\n", a[i], b[i]); }
    }
    // print the final result
    if (ok) {
        printf("TENSOR OK\n");
    } else {
        printf("TENSOR NOT OK\n");
    }
    return ok;
}

int main(int argc, char *argv[]) {

    // set up the device
    int deviceIdx = 0;
    cudaCheck(cudaSetDevice(deviceIdx));
    cudaDeviceProp deviceProp;
    cudaGetDeviceProperties(&deviceProp, deviceIdx);
    printf("[System]\n");
    printf("Device %d: %s\n", deviceIdx, deviceProp.name);

    // setup cuBLAS and cuBLASLt
    cublasCheck(cublasCreate(&cublas_handle));
    cublasCheck(cublasLtCreate(&cublaslt_handle));
    // TF32 precision is equivalent to torch.set_float32_matmul_precision('high')
    int enable_tf32 = deviceProp.major >= 8 ? 1 : 0;
    enable_tf32 = 0; // NOTE: disable TF32 for testing!!!
    printf("enable_tf32: %d\n", enable_tf32);
    cublas_compute_type = enable_tf32 ? CUBLAS_COMPUTE_32F_FAST_TF32 : CUBLAS_COMPUTE_32F;
    cublasMath_t cublas_math_mode = enable_tf32 ? CUBLAS_TF32_TENSOR_OP_MATH : CUBLAS_DEFAULT_MATH;
    cublasCheck(cublasSetMathMode(cublas_handle, cublas_math_mode));
    cudaCheck(cudaMalloc(&cublaslt_workspace, cublaslt_workspace_size));

    // build the GPT-2 model from a checkpoint
    GPT2 model;
    gpt2_build_from_checkpoint(&model, "gpt2_124M.bin");

    int C = model.config.channels;
    int V = model.config.vocab_size;
    int maxT = model.config.max_seq_len;
    int L = model.config.num_layers;

    // load additional information that we will use for debugging and error checking
    FILE *state_file = fopenCheck("gpt2_124M_debug_state.bin", "rb");
    int state_header[256];
    freadCheck(state_header, sizeof(int), 256, state_file);
    if (state_header[0] != 20240327) { printf("Bad magic state file"); exit(1); }
    if (state_header[1] != 1) { printf("Bad version in state file"); exit(1); }
    int B = state_header[2]; // batch size, e.g. 4
    int T = state_header[3]; // time / sequence length (e.g. 64, up to maxT)
    assert(0 <= T && T <= maxT);
    printf("[State]\n");
    printf("batch_size: %d\n", B);
    printf("seq_len: %d\n", T);

    ParameterTensors expected_grads; // will be read from file (from PyTorch)
    ParameterTensors calculated_grads; // will be calculated by us
    float* expected_grads_memory = malloc_and_point_parameters(&expected_grads, model.param_sizes, 0);
    float* calculated_grads_memory = malloc_and_point_parameters(&calculated_grads, model.param_sizes, 0);

    // inputs and expected outputs, only used for error checking
    int* x = (int*)mallocCheck(B * T * sizeof(int));
    int* y = (int*)mallocCheck(B * T * sizeof(int));
    float* expected_logits = (float*) mallocCheck(B * T * V * sizeof(float));
    float* expected_loss = (float*) mallocCheck(1 * sizeof(float));

    // read reference information from Python
    freadCheck(x, sizeof(int), B*T, state_file);
    freadCheck(y, sizeof(int), B*T, state_file);
    freadCheck(expected_logits, sizeof(float), B*T*V, state_file);
    freadCheck(expected_loss, sizeof(float), 1, state_file);
    freadCheck(expected_grads_memory, sizeof(float), model.num_parameters, state_file);
    fcloseCheck(state_file);

    // overall OK signal for the test
    int allok = 1;

    // let's do 10 training iterations, following the pytorch code
    float losses[10];
    for (int step = 0; step < 10; step++) {
        struct timespec start, end;
        clock_gettime(CLOCK_MONOTONIC, &start);
        gpt2_forward(&model, x, y, B, T);
        gpt2_zero_grad(&model);
        gpt2_backward(&model);
        clock_gettime(CLOCK_MONOTONIC, &end);
        double time_elapsed_s = (end.tv_sec - start.tv_sec) + (end.tv_nsec - start.tv_nsec) / 1e9;

        if (step == 0) {
            // error checking at step 0 for reference activations

            // at this point, target should be equal to expected_logits, let's compare
            // copy logits to CPU so we can compare them
            float* logits_cpu = (float*)mallocCheck(B * T * V * sizeof(float));
            cudaMemcpy(logits_cpu, model.acts.logits, B * T * V * sizeof(float), cudaMemcpyDeviceToHost);
            int logits_ok = 1;
            for (int i=0; i<B*T*V; i++) {
                if(i < 3) {
                    printf("%f %f\n", expected_logits[i], logits_cpu[i]);
                }
                if (fabsf(expected_logits[i] - logits_cpu[i]) >= 1e-2) {
                    printf("MISMATCH AT INDEX %d: ", i);
                    printf("%f %f\n", expected_logits[i],logits_cpu[i]);
                    logits_ok = 0;
                    break;
                }
            }
            if(!logits_ok) { printf("NOT "); }
            printf("OK (LOGITS)\n");
            allok = allok && logits_ok;
            free(logits_cpu);

            // compare the achieved loss
            if (fabsf(model.mean_loss - *expected_loss) >= 1e-2) {
                printf("LOSS MISMATCH: %f %f\n", model.mean_loss, *expected_loss);
                allok = 0;
            } else {
                printf("LOSS OK: %f %f\n", model.mean_loss, *expected_loss);
            }

            // look at only the last layer for now
            int l = L-1;

            // and now compare the gradients on the parameters
            cudaMemcpy(calculated_grads.lnfw, model.grads.lnfw, C * sizeof(float), cudaMemcpyDeviceToHost);
            cudaMemcpy(calculated_grads.lnfb, model.grads.lnfb, C * sizeof(float), cudaMemcpyDeviceToHost);
            cudaMemcpy(calculated_grads.fcprojw + l * C * 4*C, model.grads.fcprojw + l * C * 4*C, C * 4*C * sizeof(float), cudaMemcpyDeviceToHost);
            cudaMemcpy(calculated_grads.fcprojb + l * C, model.grads.fcprojb + l * C, C * sizeof(float), cudaMemcpyDeviceToHost);
            cudaMemcpy(calculated_grads.fcw + l * 4*C * C, model.grads.fcw + l * 4*C * C, 4*C * C * sizeof(float), cudaMemcpyDeviceToHost);
            cudaMemcpy(calculated_grads.fcb + l * 4*C, model.grads.fcb + l * 4*C, 4*C * sizeof(float), cudaMemcpyDeviceToHost);
            cudaMemcpy(calculated_grads.ln2w + l * C, model.grads.ln2w + l * C, C * sizeof(float), cudaMemcpyDeviceToHost);
            cudaMemcpy(calculated_grads.ln2b + l * C, model.grads.ln2b + l * C, C * sizeof(float), cudaMemcpyDeviceToHost);
            cudaMemcpy(calculated_grads.attprojw + l * C * C, model.grads.attprojw + l * C * C, C * C * sizeof(float), cudaMemcpyDeviceToHost);
            cudaMemcpy(calculated_grads.attprojb + l * C, model.grads.attprojb + l * C, C * sizeof(float), cudaMemcpyDeviceToHost);

            check_tensor(calculated_grads.lnfb, expected_grads.lnfb, C, "lnfb");
            check_tensor(calculated_grads.lnfw, expected_grads.lnfw, C, "lnfw");
            check_tensor(calculated_grads.fcprojw + l * C * 4*C, expected_grads.fcprojw + l * C * 4*C, C * 4*C, "fcprojw");
            check_tensor(calculated_grads.fcprojb + l * C, expected_grads.fcprojb + l * C, C, "fcprojb");
            check_tensor(calculated_grads.fcw + l * 4*C * C, expected_grads.fcw + l * 4*C * C, 4*C * C, "fcw");
            check_tensor(calculated_grads.fcb + l * 4*C, expected_grads.fcb + l * 4*C, 4*C, "fcb");
            check_tensor(calculated_grads.ln2w + l * C, expected_grads.ln2w + l * C, C, "ln2w");
            check_tensor(calculated_grads.ln2b + l * C, expected_grads.ln2b + l * C, C, "ln2b");
            check_tensor(calculated_grads.attprojw + l * C * C, expected_grads.attprojw + l * C * C, C * C, "attprojw");
            check_tensor(calculated_grads.attprojb + l * C, expected_grads.attprojb + l * C, C, "attprojb");
        }
    }

    printf("overall okay: %d\n", allok);

    // free everything
    free(x);
    free(y);
    free(expected_logits);
    free(expected_loss);
    free(expected_grads_memory);
    free(calculated_grads_memory);
    gpt2_free(&model);
    cudaCheck(cudaFree(cublaslt_workspace));
    cublasCheck(cublasDestroy(cublas_handle));
    cublasCheck(cublasLtDestroy(cublaslt_handle));

    return 0;
}