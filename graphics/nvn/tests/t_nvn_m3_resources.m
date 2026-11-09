// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// CPU contract for the production macOS 14 Metal 3 residency path. No GPU needed.
// Build from the repo root, using the normal generated NVN headers and an SDK
// with Metal 4 declarations. Undefined host functions are in uncalled code.
// xcrun clang -isysroot "$SDKROOT" -mmacosx-version-min=14.0 -fobjc-arc \
//   -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/host -Iruntime/include -I"$NVN_GEN" \
//   -Wl,-dead_strip -Wl,-undefined,dynamic_lookup \
//   -framework Foundation -framework Metal -framework MetalFX -framework QuartzCore \
//   -framework ImageIO -framework CoreGraphics -framework UniformTypeIdentifiers \
//   graphics/nvn/tests/t_nvn_m3_resources.m -o /tmp/t_nvn_m3_resources
#include "../gfx/nvn/nvn_mtl.m"
#include <assert.h>


int s2a_nvn_rast_flip;
void s2a_gpu_safe_stop(const char *why) { (void)why; abort(); }
@interface M3ProbeBuffer : NSObject {
    NSMutableData *_data;
}
@property uint64_t gpuAddress;
- (instancetype)initWithLength:(NSUInteger)length gpu:(uint64_t)gpu;
@property (readonly) NSUInteger allocatedSize, length;
@property (readonly) void *contents;
@end
@implementation M3ProbeBuffer
- (instancetype)initWithLength:(NSUInteger)length gpu:(uint64_t)gpu {
    if ((self = [super init])) { _data = [NSMutableData dataWithLength:length]; _gpuAddress = gpu; }
    return self;
}
- (BOOL)conformsToProtocol:(Protocol *)p { return p == @protocol(MTLBuffer) || [super conformsToProtocol:p]; }
- (NSUInteger)allocatedSize { return _data.length; }
- (NSUInteger)length { return _data.length; }
- (void *)contents { return _data.mutableBytes; }
@end

@interface M3ProbeTexture : NSObject
@property (readonly) id parentTexture, buffer;
@end
@implementation M3ProbeTexture
- (BOOL)conformsToProtocol:(Protocol *)p { return p == @protocol(MTLTexture) || [super conformsToProtocol:p]; }
- (BOOL)isEqual:(id)other { return [other isKindOfClass:[M3ProbeTexture class]]; }   // Distinct views can compare equal.
- (NSUInteger)hash { return 1; }
- (id)parentTexture { return nil; }
- (id)buffer { return nil; }
@end

@interface M3ProbeSampler : NSObject @end
@implementation M3ProbeSampler
- (BOOL)conformsToProtocol:(Protocol *)p { return p == @protocol(MTLSamplerState) || [super conformsToProtocol:p]; }
@end

@interface M3ProbeDevice : NSObject @end
@implementation M3ProbeDevice
- (id)newSamplerStateWithDescriptor:(MTLSamplerDescriptor *)descriptor {
    (void)descriptor;
    return [M3ProbeSampler new];
}
- (id)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options {
    (void)options;
    static uint64_t gpu = 0x100000;
    gpu += 0x10000;
    return [[M3ProbeBuffer alloc] initWithLength:length gpu:gpu];
}
@end

@interface M3ProbeCB : NSObject
@property (copy) MTLCommandBufferHandler complete;
@property NSUInteger plainPresents, timedPresents;
@property CFTimeInterval minimumDuration;
@end
@implementation M3ProbeCB
- (void)addCompletedHandler:(MTLCommandBufferHandler)fn {
    assert(!self.complete);
    self.complete = fn;
}
- (void)presentDrawable:(id<MTLDrawable>)drawable {
    assert(drawable);
    self.plainPresents++;
}
- (void)presentDrawable:(id<MTLDrawable>)drawable afterMinimumDuration:(CFTimeInterval)duration {
    assert(drawable);
    self.timedPresents++;
    self.minimumDuration = duration;
}
@end

@interface M3ProbeDrawable : NSObject @end
@implementation M3ProbeDrawable
- (void)addPresentedHandler:(MTLDrawablePresentedHandler)handler { assert(handler); }
@end
@interface M3ProbeEncoder : NSObject
@property NSUInteger nread, nwrite, count;
@property MTLRenderStages readStages, writeStages;
@end
@implementation M3ProbeEncoder
- (void)useResources:(const id<MTLResource> [])resources count:(NSUInteger)count
               usage:(MTLResourceUsage)usage stages:(MTLRenderStages)stages {
    self.count++;
    for (NSUInteger i = 0; i < count; i++) assert(resources[i]);
    if (usage & MTLResourceUsageWrite) { self.nwrite += count; self.writeStages = stages; }
    else { self.nread += count; self.readStages = stages; }
}
- (void)useResources:(const id<MTLResource> [])resources count:(NSUInteger)count usage:(MTLResourceUsage)usage {
    [self useResources:resources count:count usage:usage stages:0];
}
@end

static void test_immediate(void) {
    M3ProbeCB *cb = [M3ProbeCB new];
    M3ProbeEncoder *en = [M3ProbeEncoder new];
    __weak id wb, wt, replacement;
    @autoreleasepool {
        id b = [(id)g_dev newBufferWithLength:256 options:0]; wb = b; res_add(b);
        id t = [M3ProbeTexture new]; wt = t;
        DmM3Residency *r = m3_encoder_residency(en);
        m3_note_resource(r, t, MTLResourceUsageRead, MTLRenderStageVertex);
        assert(en.count == 0);
        m3_declare_indirect(cb, en, MTLRenderStageVertex | MTLRenderStageFragment);
        assert(en.nwrite == 1 && en.nread == 1 && en.readStages == MTLRenderStageVertex);
        m3_declare_indirect(cb, en, MTLRenderStageVertex | MTLRenderStageFragment);
        assert(en.count == 2);
        m3_note_resource(r, t, MTLResourceUsageWrite, MTLRenderStageFragment);
        m3_declare_indirect(cb, en, MTLRenderStageVertex | MTLRenderStageFragment);
        assert(en.nwrite == 2 && en.nread == 1 && en.writeStages == (MTLRenderStageVertex | MTLRenderStageFragment));
        id t2 = [M3ProbeTexture new]; replacement = t2;
        m3_note_resource(r, t2, MTLResourceUsageRead, MTLRenderStageFragment);
        id b2 = [(id)g_dev newBufferWithLength:256 options:0]; res_add(b2);
        m3_declare_indirect(cb, en, MTLRenderStageVertex | MTLRenderStageFragment);
        assert(en.nwrite == 4 && en.nread == 2 && en.readStages == MTLRenderStageFragment);
        res_remove(b); res_remove(b2);
    }
    assert(wb && wt && replacement && cb.complete);
    cb.complete((id)cb);
    assert(!wb && !wt && !replacement);
}

static void test_recorded(void) {
    M3ProbeCB *cb = [M3ProbeCB new];
    M3ProbeEncoder *en = [M3ProbeEncoder new];
    DmRecEnc *rec = [DmRecEnc new];
    __weak id wb, wt, ws;
    @autoreleasepool {
        id b = [(id)g_dev newBufferWithLength:256 options:0]; wb = b; res_add(b);
        id t = [M3ProbeTexture new]; wt = t;
        id sampler = [M3ProbeSampler new]; ws = sampler;
        DmM3Residency *r = m3_encoder_residency(rec);
        m3_note_resource(r, t, MTLResourceUsageRead, 0);
        m3_note_resource(r, sampler, MTLResourceUsageRead, 0);
        rec_lane(1);
        m3_declare_indirect(nil, rec, 0);
        rec_lane(0);
        res_remove(b);
    }
    assert(wb && wt && ws && !cb.complete && en.count == 0);
    assert(g_lane_head[1] && g_lane_head[1]->n == 3);
    g_rx_cb = cb; g_rx_enc = en;
    for (int i = 0; i < g_lane_head[1]->n; i++) rec_exec(&g_lane_head[1]->r[i]);
    g_rx_cb = g_rx_enc = nil;
    assert(wb && wt && ws && cb.complete && en.nwrite == 1 && en.nread == 1);
    cb.complete((id)cb);
    assert(!wb && !wt && !ws);
}

static void test_pool(void) {
    M3ProbeBuffer *b = [(id)g_dev newBufferWithLength:256 options:0];
    uint64_t *handles = (uint64_t *)((uint8_t *)[b contents] + DMSH_POOL_HEAD);
    *(uint32_t *)[b contents] = 1; handles[0] = 11; handles[1] = 11;
    g_ptab[0] = (pool_tab){.buf = (id)b, .gpu = [b gpuAddress], .dummy = 11, .n = 1, .cap = 2, .used = 1, .samp = 1, .obj = calloc(2, sizeof(void *))};
    pool_m3_publish(&g_ptab[0], [DmM3Residency new], 0);
    uint64_t gen = g_psnap_gen;
    pool_ent_put(0, 0, NULL, 0);
    assert(g_ptab[0].buf == b && g_psnap_gen == gen);
    pool_ent_put(0, 0, (__bridge void *)[M3ProbeSampler new], 22);
    assert(g_ptab[0].buf != b && g_psnap_gen == gen + 1 && handles[0] == 11);
    uint64_t *copy = (uint64_t *)((uint8_t *)g_ptab[0].buf.contents + DMSH_POOL_HEAD);
    assert(copy[0] == 22 && copy[1] == 11);
    pool_ent_put(0, 0, NULL, 0);
    assert(copy[0] == 11 && g_psnap_gen == gen + 1);
    pool_m3_publish(&g_ptab[0], [DmM3Residency new], 0);
    id sampler = [M3ProbeSampler new];
    pool_ent_put(0, 0, (__bridge void *)sampler, 33);
    pool_m3_publish(&g_ptab[0], [DmM3Residency new], 0);
    M3ProbeBuffer *before_growth = (id)g_ptab[0].buf;
    pool_tab_put_n(&g_ptab[0], 3);
    assert(before_growth != (id)g_ptab[0].buf && *(const uint32_t *)before_growth.contents == 1);
    assert(*(const uint32_t *)g_ptab[0].buf.contents == 3);
    pool_m3_publish(&g_ptab[0], [DmM3Residency new], 0);
    M3ProbeBuffer *retired = (id)g_ptab[0].buf;
    uint64_t *old = (uint64_t *)((uint8_t *)retired.contents + DMSH_POOL_HEAD);
    pool_tab_drop(0);
    assert(old[0] == 33);   // Eviction may unpin the object, but must leave the published bytes intact.
}

static void test_batches(void) {
    M3ProbeCB *cb = [M3ProbeCB new];
    M3ProbeEncoder *en = [M3ProbeEncoder new];
    DmM3Residency *r = m3_encoder_residency(en);
    for (NSUInteger i = 0; i < 257; i++)
        m3_note_resource(r, [M3ProbeTexture new], MTLResourceUsageRead, MTLRenderStageFragment);
    m3_declare_indirect(cb, en, MTLRenderStageVertex | MTLRenderStageFragment);
    assert(en.nread == 257 && en.count == 3 && en.readStages == MTLRenderStageFragment);
    cb.complete((id)cb);
}

static void test_present_handoff(void) {
    M3ProbeCB *cb = [M3ProbeCB new];
    M3ProbeDrawable *drawable = [M3ProbeDrawable new];
    const double period = 1.0 / 60;
    present_m3((id)cb, (id)drawable, 1, period, YES);
    assert(cb.plainPresents == 1 && cb.timedPresents == 0);
    present_m3((id)cb, (id)drawable, 2, period, NO);
    assert(cb.plainPresents == 1 && cb.timedPresents == 1 && cb.minimumDuration == period);
    present_m3((id)cb, (id)drawable, 3, 0, NO);
    assert(cb.plainPresents == 2 && cb.timedPresents == 1);

    // During the handoff, the classic thread has committed and returned, but
    // the GPU queue still owns its command buffer's timed present.
    pthread_mutex_lock(&g_pq_mu);
    assert(!link_handoff_pending());
    g_classic_busy = 1;
    assert(link_handoff_pending());
    g_classic_busy = 0;
    g_pq_inflight = 1;
    assert(link_handoff_pending());
    g_m3 = 0;
    assert(!link_handoff_pending());   // Metal 4 presents synchronously before handing over.
    g_m3 = 1;
    g_pq_inflight = 0;
    assert(!link_handoff_pending());
    pthread_mutex_unlock(&g_pq_mu);
}

int main(void) {
    @autoreleasepool {
        g_m3 = g_m3_explicit_residency = 1;
        g_dev = (id)[M3ProbeDevice new];
        test_immediate();
        test_recorded();
        test_batches();
        test_pool();
        puts("NVN Metal 3 residency: immediate, recorded, immutable pool, and 257-view batching passed");
        test_present_handoff();
        puts("NVN Metal 3 presentation: API selection and classic-to-link handoff passed");
    }
}
