/*
AdamW kernel
*/

// llmc internal imports
#include "cuda_common.h"
#include "cuda_utils.cuh"
#include "bits.cuh"

// ----------------------------------------------------------------------------
// CUDA kernels

// Implements linear interpolation using only two floating-point operations (as opposed to three in a naive implementation).
// Reference: https://developer.nvidia.com/blog/lerp-faster-cuda
__device__ float lerp(float start, float end, float weight) {
    return fma(weight, end, fma(-weight, start, start));
}

template <typename Tp, typename Tg>
__device__ void adamw_update(Tp* params_memory, unsigned short* mantissas, Tg* grads_memory, float* m_memory, float* v_memory, size_t num_parameters,
                             float learning_rate, float beta1, float beta2, float beta1_correction, float beta2_correction, float eps, float weight_decay,
                             float grad_scale, unsigned int seed) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= num_parameters) { return; }  // guard

    // get the gradient, m, and v for this parameter
    float grad = grad_scale * (float)grads_memory[idx];
    float m = m_memory[idx];
    float v = v_memory[idx];
    // update the first moment (momentum)
    m = lerp(grad, m, beta1);
    m_memory[idx] = m;
    // update the second moment (RMSprop)
    v = lerp(grad * grad, v, beta2);
    v_memory[idx] = v;
    m /= beta1_correction;  // m_hat
    v /= beta2_correction;  // v_hat
    // fetch the old value of this parameter as a float, from either source
    float old_param;
    if (mantissas != NULL) {
        if constexpr (std::is_same_v<Tp, __nv_bfloat16>) {
            old_param = assemble_float(params_memory[idx], mantissas[idx]);
        } else {
            assert(false && "Master params are only implemented for bf16.");
        }
    } else {
        old_param = (float)params_memory[idx];
    }
    // update this parameter in 32-bit precision
    float param = old_param - (learning_rate * (m / (sqrtf(v) + eps) + weight_decay * old_param));

    // update our low precision version of the parameters using stochastic rounding
    // this will be used in the next forward pass
    // TODO: simply doing `params_memory[i] = (floatX)param;` breaks everything (why?)

    // If we keep master parameter "copies", make sure to store the missing bits in the 'mantissas' array,
    // otherwise we can directly go for stochastic rounding.
    if (mantissas != NULL) {
        if constexpr (std::is_same_v<Tp, __nv_bfloat16>) {
            unsigned int random = Get2dNoiseUint(threadIdx.x, blockIdx.x * blockDim.x + blockIdx.y, seed);
            unsigned int threshold = random & 0xFFFFu;
            SplitFloatResult split = split_float(param, threshold);
            mantissas[idx] = split.bits;
            params_memory[idx] = split.b_float;
        } else {
            assert(false && "Master params are only implemented for bf16.");
        }
    } else {
        stochastic_rounding(param, &params_memory[idx], seed);
    }
}

template <typename Tp, typename Tg>
__global__ void adamw_kernel3(Tp* params_memory, unsigned short* mantissas, Tg* grads_memory, float* m_memory, float* v_memory, size_t num_parameters,
                              ptrdiff_t w_stride, ptrdiff_t g_stride, ptrdiff_t s_stride,
                              float learning_rate, float beta1, float beta2, float beta1_correction, float beta2_correction, float eps, float weight_decay,
                              float grad_scale, unsigned int seed) {
    adamw_update(params_memory + blockIdx.y * w_stride,
                 mantissas ? mantissas + blockIdx.y * s_stride : NULL,
                 grads_memory + blockIdx.y * g_stride,
                 m_memory + blockIdx.y * s_stride,
                 v_memory + blockIdx.y * s_stride,
                 num_parameters, learning_rate, beta1, beta2, beta1_correction, beta2_correction, eps, weight_decay, grad_scale,
                 seed
                 );
}

template <typename Tp, typename Tg>
void adamw_update(Tp* params_memory, unsigned short* mantissas, Tg* grads_memory, float* m_memory, float* v_memory, size_t num_parameters,
                  ptrdiff_t w_stride, ptrdiff_t g_stride, ptrdiff_t s_stride,  int num_slices, float learning_rate, float beta1, float beta2, int t, float eps, float weight_decay,
                  float grad_scale, unsigned int seed, cudaStream_t stream) {
    // AdamW update
    int block_size = 512;
    int num_blocks = CEIL_DIV(num_parameters, block_size);
    float beta1_correction = 1.0f - powf(beta1, t);
    float beta2_correction = 1.0f - powf(beta2, t);
    adamw_kernel3<<<dim3(num_blocks, num_slices), block_size, 0, stream>>>(params_memory, mantissas, grads_memory,
                                                         m_memory, v_memory, num_parameters, w_stride, g_stride, s_stride,
                                                         learning_rate, beta1, beta2, beta1_correction, beta2_correction, eps, weight_decay,
                                                         grad_scale, seed);
    cudaCheck(cudaGetLastError());
}