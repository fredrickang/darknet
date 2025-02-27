#include <cuda_runtime.h>
#include <curand.h>
#include <cublas_v2.h>

#include "maxpool_layer.h"
#include "dark_cuda.h"
extern FILE *pFile;
__global__ void forward_maxpool_depth_layer_kernel(int n, int w, int h, int c, int out_c, int batch, float *input, float *output, int *indexes)
{
    int id = (blockIdx.x + blockIdx.y*gridDim.x) * blockDim.x + threadIdx.x;
    if (id >= n) return;

    int j = id % w;
    id = id / w;
    int i = id % h;
    id = id / h;
    //int g = id % out_c;
    //id = id / out_c;
    int b = id % batch;

    int k;
    for (int g = 0; g < out_c; ++g)
    {
        int out_index = j + w*(i + h*(g + out_c*b));
        float max = -FLT_MAX;
        int max_i = -1;

        for (k = g; k < c; k += out_c)
        {
            int in_index = j + w*(i + h*(k + c*b));
            float val = input[in_index];

            max_i = (val > max) ? in_index : max_i;
            max = (val > max) ? val : max;
        }
        output[out_index] = max;
        indexes[out_index] = max_i;
    }
}


__global__ void backward_maxpool_depth_layer_kernel(int n, int w, int h, int c, int batch, float *delta, float *prev_delta, int *indexes)
{
    int id = (blockIdx.x + blockIdx.y*gridDim.x) * blockDim.x + threadIdx.x;
    if (id >= n) return;

    int index = indexes[id];
    prev_delta[index] += delta[id];
}


__global__ void forward_maxpool_layer_kernel(int n, int in_h, int in_w, int in_c, int stride, int size, int pad, float *input, float *output, int *indexes)
{
    int h = (in_h + pad - size) / stride + 1;
    int w = (in_w + pad - size) / stride + 1;
    int c = in_c;

    int id = (blockIdx.x + blockIdx.y*gridDim.x) * blockDim.x + threadIdx.x;
    if(id >= n) return;

    int j = id % w;
    id /= w;
    int i = id % h;
    id /= h;
    int k = id % c;
    id /= c;
    int b = id;

    int w_offset = -pad / 2;
    int h_offset = -pad / 2;

    int out_index = j + w*(i + h*(k + c*b));
    float max = -INFINITY;
    int max_i = -1;
    int l, m;
    for(l = 0; l < size; ++l){
        for(m = 0; m < size; ++m){
            int cur_h = h_offset + i*stride + l;
            int cur_w = w_offset + j*stride + m;
            int index = cur_w + in_w*(cur_h + in_h*(k + b*in_c));
            int valid = (cur_h >= 0 && cur_h < in_h &&
                    cur_w >= 0 && cur_w < in_w);
            float val = (valid != 0) ? input[index] : -INFINITY;
            max_i = (val > max) ? index : max_i;
            max   = (val > max) ? val   : max;
        }
    }
    output[out_index] = max;
    indexes[out_index] = max_i;
}

__global__ void backward_maxpool_layer_kernel(int n, int in_h, int in_w, int in_c, int stride, int size, int pad, float *delta, float *prev_delta, int *indexes)
{
    int h = (in_h + pad - size) / stride + 1;
    int w = (in_w + pad - size) / stride + 1;
    int c = in_c;
    int area = (size-1)/stride;

    int id = (blockIdx.x + blockIdx.y*gridDim.x) * blockDim.x + threadIdx.x;
    if(id >= n) return;

    int index = id;
    int j = id % in_w;
    id /= in_w;
    int i = id % in_h;
    id /= in_h;
    int k = id % in_c;
    id /= in_c;
    int b = id;

    int w_offset = -pad / 2;
    int h_offset = -pad / 2;

    float d = 0;
    int l, m;
    for(l = -area; l < area+1; ++l){
        for(m = -area; m < area+1; ++m){
            int out_w = (j-w_offset)/stride + m;
            int out_h = (i-h_offset)/stride + l;
            int out_index = out_w + w*(out_h + h*(k + c*b));
            int valid = (out_w >= 0 && out_w < w &&
                     out_h >= 0 && out_h < h);
            d += (valid && indexes[out_index] == index) ? delta[out_index] : 0;
        }
    }
    prev_delta[index] += d;
}

extern "C" void forward_maxpool_layer_gpu(maxpool_layer layer, network_state state)
{
#ifdef EXE_TIME 
    double time = get_time_point();
#endif
    if (layer.maxpool_depth) {
        int h = layer.out_h;
        int w = layer.out_w;
        int c = 1;// layer.out_c;

        size_t n = h*w*c*layer.batch;

        forward_maxpool_depth_layer_kernel << <cuda_gridsize(n), BLOCK, 0, get_cuda_stream() >> >(
            n, layer.w, layer.h, layer.c, layer.out_c, layer.batch, state.input, layer.output_gpu, layer.indexes_gpu);
        CHECK_CUDA(cudaPeekAtLastError());
        CHECK_CUDA(cudaDeviceSynchronize());
#ifdef EXE_TIME
        printf("Thread: %d Maxpool - Performed in %10.3f milli-seconds.\n", pthread_self(),((double)get_time_point() - time) / 1000);
#endif
        return;
    }

#ifdef CUDNN_DISABLED
    if (!state.train && layer.stride == layer.size) {
        // cudnnPoolingBackward
        cudnnStatus_t maxpool_status;

        float alpha = 1, beta = 0;
        maxpool_status = cudnnPoolingForward(
            cudnn_handle(),
            layer.poolingDesc,
            &alpha,
            layer.srcTensorDesc,
            state.input,
            &beta,
            layer.dstTensorDesc,
            layer.output_gpu);

        //maxpool_status = cudnnDestroyPoolingDescriptor(poolingDesc);
        //cudnnDestroyTensorDescriptor(layer.srcTensorDesc);
        //cudnnDestroyTensorDescriptor(layer.dstTensorDesc);
#ifdef EXE_TIME
        printf("Thread: %d Maxpool - Performed in %10.3f milli-seconds.\n", ((double)get_time_point() - time) / 1000);
#endif
        return;
    }
#endif

    int h = layer.out_h;
    int w = layer.out_w;
    int c = layer.out_c;

    size_t n = h*w*c*layer.batch;

    forward_maxpool_layer_kernel<<<cuda_gridsize(n), BLOCK, 0, get_cuda_stream()>>>(n, layer.h, layer.w, layer.c, layer.stride, layer.size, layer.pad, state.input, layer.output_gpu, layer.indexes_gpu);
    CHECK_CUDA(cudaPeekAtLastError());
    CHECK_CUDA(cudaDeviceSynchronize());
#ifdef EXE_TIME
    printf("Thread: %d Maxpool - Performed in %10.3f milli-seconds.\n", ((double)get_time_point() - time) / 1000);
#endif
}

extern "C" void backward_maxpool_layer_gpu(maxpool_layer layer, network_state state)
{
    if (layer.maxpool_depth) {
        int h = layer.out_h;
        int w = layer.out_w;
        int c = layer.out_c;

        size_t n = h * w * c * layer.batch;

        backward_maxpool_depth_layer_kernel << <cuda_gridsize(n), BLOCK, 0, get_cuda_stream() >> >(n, layer.w, layer.h, layer.c, layer.batch, layer.delta_gpu, state.delta, layer.indexes_gpu);
        CHECK_CUDA(cudaPeekAtLastError());
        return;
    }

    size_t n = layer.h*layer.w*layer.c*layer.batch;

    backward_maxpool_layer_kernel<<<cuda_gridsize(n), BLOCK, 0, get_cuda_stream() >>>(n, layer.h, layer.w, layer.c, layer.stride, layer.size, layer.pad, layer.delta_gpu, state.delta, layer.indexes_gpu);
    CHECK_CUDA(cudaPeekAtLastError());
}
