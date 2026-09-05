#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

/// Water-drop ripple for the expand transition: a damped sine wave travels
/// outward from `origin`, displacing each sample radially (the refraction)
/// and brightening the crests (the glints). Only the SwiftUI-rendered layer
/// — scrim and content — runs through this; the live glass backdrop is
/// composited by the window server and cannot be sampled here.
[[ stitchable ]] half4 expansionRipple(
    float2 position,
    SwiftUI::Layer layer,
    float2 origin,
    float time,
    float amplitude,
    float frequency,
    float decay,
    float speed,
    float crest
) {
    float dist = length(position - origin);
    float delay = dist / speed;
    float t = max(0.0, time - delay);
    // Fade the displacement out at the impact itself. The field is radial and
    // therefore singular there — without this, samples on opposite sides of the
    // origin are dragged past one another and the surface tears open. Tapering
    // over `amplitude` bounds the displacement by the distance to the origin,
    // which is precisely the condition for the warp not to fold. The same taper
    // is mirrored in `ReleaseRippleShader.displacement`, so the silhouette
    // traced in Swift keeps matching the pixels bent here.
    float taper = amplitude > 0.0 ? min(1.0, dist / amplitude) : 0.0;
    float rippleAmount = amplitude * sin(frequency * t) * exp(-decay * t) * taper;
    float2 direction = dist > 0.001 ? (position - origin) / dist : float2(0.0, 0.0);
    half4 color = layer.sample(position + rippleAmount * direction);
    // Crest highlight: proportional to the local displacement, scaled by alpha
    // so the transparent surround never glows. The strength is a caller-supplied
    // uniform (`crest`) so the two surfaces sharing this shader tune
    // independently: the notch's dark low-alpha scrim needs a bright glint to
    // read through, while the region capture's opaque frame blows out to white
    // at that same strength and wants a much gentler value.
    color.rgb += crest * (amplitude > 0.0 ? rippleAmount / amplitude : 0.0) * color.a;
    return color;
}
