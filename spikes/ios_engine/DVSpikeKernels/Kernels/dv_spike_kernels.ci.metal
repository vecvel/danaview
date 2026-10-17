// IOS-01 spike (V-N9): Core Image kernels written in the Metal Shading Language and compiled with
// `-fcikernel` (MTL_COMPILER_FLAGS) / linked with `-cikernel` (MTLLINKER_FLAGS) into the pod's
// resource bundle default.metallib. Loaded with CIKernel(functionName:fromMetalLibraryData:).
//
// dv_look implements the grade subset of ARCH §11.6 (exposure, brightness/contrast, saturation)
// on straight alpha; dv_blur_h/v are the separable Gaussian (radius ceil(3σ)).
#include <metal_stdlib>
using namespace metal;
#include <CoreImage/CoreImage.h>

extern "C" { namespace coreimage {

float4 dv_look(sample_t s, float exposure, float brightness, float contrast, float saturation) {
    float a = s.a;
    float3 c = a > 0.0 ? s.rgb / a : float3(0.0);
    c = pow(pow(max(c, float3(0.0)), float3(2.2)) * exp2(2.0 * exposure), float3(1.0 / 2.2));
    c += brightness / 4.0;
    c = (c - 0.5) * (1.0 + contrast) + 0.5;
    float y = dot(c, float3(0.2126, 0.7152, 0.0722));
    c = mix(float3(y), c, 1.0 + saturation);
    c = clamp(c, 0.0, 1.0);
    return float4(c * a, a);
}

float4 dv_blur_h(sampler src, float sigma, destination dest) {
    float2 dc = dest.coord();
    int r = int(ceil(3.0 * sigma));
    float4 acc = float4(0.0);
    float wsum = 0.0;
    for (int i = -r; i <= r; i++) {
        float w = exp(-float(i * i) / (2.0 * sigma * sigma));
        acc += w * src.sample(src.transform(dc + float2(float(i), 0.0)));
        wsum += w;
    }
    return acc / wsum;
}

float4 dv_blur_v(sampler src, float sigma, destination dest) {
    float2 dc = dest.coord();
    int r = int(ceil(3.0 * sigma));
    float4 acc = float4(0.0);
    float wsum = 0.0;
    for (int i = -r; i <= r; i++) {
        float w = exp(-float(i * i) / (2.0 * sigma * sigma));
        acc += w * src.sample(src.transform(dc + float2(0.0, float(i))));
        wsum += w;
    }
    return acc / wsum;
}

}}
