// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// CPU test of shader_build with synthetic reflection and Metal function metadata.
#include "../gfx/nvn/nvn_mtl.m"

int s2a_nvn_rast_flip;
void s2a_gpu_safe_stop(const char *why) { (void)why; abort(); }

@interface RoleFunction : NSObject
@property MTLFunctionType functionType;
@property (readonly) NSDictionary *functionConstantsDictionary;
@end

@implementation RoleFunction
- (NSDictionary *)functionConstantsDictionary { return @{}; }
@end

@interface RoleLibrary : NSObject
@property (nonatomic, strong) RoleFunction *function;
@property (nonatomic, strong) RoleFunction *depthFunction;
@end

@implementation RoleLibrary
- (id<MTLFunction>)newFunctionWithName:(NSString *)name {
    if ([name isEqual:@"main0_z"]) return (id<MTLFunction>)self.depthFunction;
    return [name isEqual:@"main0"] ? (id<MTLFunction>)self.function : nil;
}
@end

@interface RoleDevice : NSObject
@property (nonatomic, strong) RoleLibrary *library;
@end

@implementation RoleDevice
- (id<MTLLibrary>)newLibraryWithData:(dispatch_data_t)data error:(NSError **)error {
    (void)data;
    (void)error;
    return (id<MTLLibrary>)self.library;
}
@end

static unsigned checks, failures;

static void check(BOOL ok, const char *name) {
    checks++;
    failures += !ok;
    printf("%s %s\n", ok ? "PASS" : "FAIL", name);
}

static NvShader *load_role(RoleDevice *dev, int stage, MTLFunctionType function_type, NSDictionary *fields) {
    NSMutableDictionary *json = [@{@"chain": @DMSH_CHAIN, @"route": @"B", @"bindings": @[], @"entry": @"main0"} mutableCopy];
    [json addEntriesFromDictionary:fields];
    NSData *bytes = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
    if (![bytes writeToFile:[g_msl_dir stringByAppendingPathComponent:@"1111111111111111_b.json"] atomically:YES]) exit(2);
    dev.library.function.functionType = function_type;
    return shader_build(@"1111111111111111_b", stage, 0, 0);
}

int main(void) {
    @autoreleasepool {
        char dir[] = "/tmp/t_nvn_shader_roles.XXXXXX";
        if (!mkdtemp(dir)) return 2;
        g_msl_dir = @(dir);
        if (![@"synthetic library bytes" writeToFile:[g_msl_dir stringByAppendingPathComponent:@"1111111111111111_b.metallib"]
                                         atomically:YES encoding:NSUTF8StringEncoding error:nil]) return 2;
        RoleDevice *dev = [RoleDevice new];
        dev.library = [RoleLibrary new];
        dev.library.function = [RoleFunction new];
        g_dev = (id<MTLDevice>)dev;

        NSDictionary *hs = @{@"stage": @"hs", @"msl_entry_kind": @"kernel", @"tess": @{@"mode": @0,
                             @"variants": @{@"triangles": @{@"output_control_points": @4}}}};
        NSDictionary *ds = @{@"stage": @"ds", @"msl_entry_kind": @"vertex", @"tess": @{@"mode": @0x121, @"variants": @{}}};
        NSDictionary *ts = @{@"stage": @"ts", @"msl_entry_kind": @"object", @"mesh_threads": @32, @"mesh_payload": @4};
        NSDictionary *ms = @{@"stage": @"ms", @"msl_entry_kind": @"mesh", @"mesh_threads": @32,
                             @"mesh_task": @YES, @"max_vertices": @4, @"max_primitives": @2};

        NvShader *hull = load_role(dev, 3, MTLFunctionTypeKernel, hs);
        check(hull && hull->mesh_kind == 0 && hull->tess_ocp == 4 && hull->tess_variants.count == 1, "stage 3 accepts Hull kernel and loads tess variants");
        NvShader *domain = load_role(dev, 4, MTLFunctionTypeVertex, ds);
        check(domain && domain->mesh_kind == 0 && domain->tess_mode == 0x121, "stage 4 accepts Domain vertex function and loads tess mode");
        NvShader *task = load_role(dev, 3, MTLFunctionTypeObject, ts);
        check(task && task->mesh_kind == 1 && task->mesh_threads == 32 && task->mesh_payload == 4, "stage 3 accepts Task object function and loads workgroup metadata");
        NvShader *mesh = load_role(dev, 4, MTLFunctionTypeMesh, ms);
        check(mesh && mesh->mesh_kind == 2 && mesh->mesh_task && mesh->mesh_maxv == 4 && mesh->mesh_maxp == 2, "stage 4 accepts Mesh function and loads limits");

        NSMutableDictionary *bad = [ts mutableCopy];
        bad[@"msl_entry_kind"] = @"mesh";
        check(!load_role(dev, 3, MTLFunctionTypeMesh, bad), "Task reflection cannot declare a Mesh entry");
        check(!load_role(dev, 3, MTLFunctionTypeKernel, ts), "Task reflection cannot disguise a kernel as an object function");
        check(!load_role(dev, 4, MTLFunctionTypeVertex, ms), "Mesh reflection cannot disguise a vertex function as a mesh function");
        check(!load_role(dev, 3, MTLFunctionTypeObject, ms), "Mesh reflection cannot occupy the Task slot");
        check(!load_role(dev, 4, MTLFunctionTypeKernel, hs), "Hull reflection cannot occupy the Domain slot");
        check(!load_role(dev, 3, MTLFunctionTypeObject, hs), "Hull reflection requires a real kernel");

        bad = [ms mutableCopy];
        bad[@"max_vertices"] = @257;
        check(!load_role(dev, 4, MTLFunctionTypeMesh, bad), "Mesh vertex limit still rejects 257 vertices");
        bad = [hs mutableCopy];
        bad[@"tess"] = @"invalid";
        check(!load_role(dev, 3, MTLFunctionTypeKernel, bad), "Hull reflection requires tess metadata");
        bad[@"tess"] = @{@"mode": NSNull.null};
        check(!load_role(dev, 3, MTLFunctionTypeKernel, bad), "Hull rejects a null tessellation mode");
        bad[@"tess"] = @{@"mode": @0, @"variants": @{@"triangles": @{@"output_control_points": NSNull.null}}};
        check(!load_role(dev, 3, MTLFunctionTypeKernel, bad), "Hull rejects a null output control point count");
        bad = [ts mutableCopy];
        bad[@"tess"] = hs[@"tess"];
        check(!load_role(dev, 3, MTLFunctionTypeObject, bad), "Task reflection with Hull metadata is rejected");
        [bad removeObjectForKey:@"tess"];
        [bad removeObjectForKey:@"stage"];
        check(!load_role(dev, 3, MTLFunctionTypeObject, bad), "Task reflection needs an explicit stage role");
        bad = [ms mutableCopy];
        [bad removeObjectForKey:@"msl_entry_kind"];
        check(!load_role(dev, 4, MTLFunctionTypeMesh, bad), "Mesh reflection needs an explicit entry kind");

        bad = [ms mutableCopy];
        bad[@"entry_z"] = @"main0_z";
        (void)load_role(dev, 4, MTLFunctionTypeMesh, bad);
        NvShader *mesh_z = shader_build(@"1111111111111111_b", 4, 0, 1);
        check(mesh_z && [mesh_z->ventry isEqual:@"main0"], "Missing near=0 mesh function keeps the GL convention");
        dev.library.depthFunction = [RoleFunction new];
        dev.library.depthFunction.functionType = MTLFunctionTypeMesh;
        mesh_z = shader_build(@"1111111111111111_b", 4, 0, 1);
        check(mesh_z && [mesh_z->ventry isEqual:@"main0_z"] && mesh_z->fn == (id<MTLFunction>)dev.library.depthFunction,
              "Near=0 chooses the mesh depth variant");
        dev.library.depthFunction.functionType = MTLFunctionTypeVertex;
        check(!shader_build(@"1111111111111111_b", 4, 0, 1), "Near=0 rejects a vertex depth variant for Mesh");

        [NSFileManager.defaultManager removeItemAtPath:g_msl_dir error:nil];
        printf("%s t_nvn_shader_roles: %u checks, %u failures\n", failures ? "✗" : "✓", checks, failures);
        return failures != 0;
    }
}
