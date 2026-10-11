// IOS-01 spike (V-N9 alternative): the same kernels as DVSpikeKernels/dv_spike_kernels.ci.metal,
// written as `[[stitchable]]` Core Image kernels (iOS 15+), compiled by Xcode's default Metal
// build rules WITHOUT -fcikernel / -cikernel.
#include <metal_stdlib>
using namespace metal;
#include <CoreImage/CoreImage.h>

extern "C" {

[[stitchable]] float4 dv_look_st(coreimage::sample_t s, float exposure, float brightness,
                                 float contrast, float saturation) {
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

[[stitchable]] float4 dv_blur_h_st(coreimage::sampler src, float sigma, coreimage::destination dest) {
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

}
