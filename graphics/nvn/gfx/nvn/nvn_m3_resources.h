// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#pragma once

// Metal 3 without a residency set. Classic useResources does not retain its
// arguments. Keep indirect resources for the lifetime of their GPU work,
// including views whose handles are embedded in an argument buffer.
static char g_m3_resources_key;
static void m3_resources_encode(id<MTLCommandBuffer> cb, id enc, NSArray *resources,
                                MTLResourceUsage usage, MTLRenderStages stages) {
    if (!resources.count) return;
    NSHashTable *keep = objc_getAssociatedObject(cb, &g_m3_resources_key);
    if (!keep) {
        keep = [[NSHashTable alloc] initWithOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality capacity:0];
        objc_setAssociatedObject(cb, &g_m3_resources_key, keep, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [cb addCompletedHandler:^(__unused id<MTLCommandBuffer> done) {
            @autoreleasepool { [keep removeAllObjects]; }
        }];
    }
    for (id resource in resources) [keep addObject:resource];
    if (!usage) return;   // Sampler states are not MTLResources, but raw IDs still need their objects to live.
    enum { BATCH = 128 };
    __unsafe_unretained id<MTLResource> batch[BATCH];
    for (NSUInteger off = 0; off < resources.count; off += BATCH) {
        NSUInteger count = MIN(BATCH, resources.count - off);
        [resources getObjects:batch range:NSMakeRange(off, count)];
        if (stages) [(id<MTLRenderCommandEncoder>)enc useResources:batch count:count usage:usage stages:stages];
        else [(id<MTLComputeCommandEncoder>)enc useResources:batch count:count usage:usage];
    }
}
