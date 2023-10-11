const std = @import("std");
const janet = @import("janet");

pub fn main() !void {
    try janet.init();
    const env = janet.Environment.coreEnv(null);
    // var env_ = janet.Table.initDynamic(0);
    // env_.proto = core_env.toTable();
    // const env = env_.toEnvironment();
    // janet.gcRoot(env_.wrap()); // this doesn't fix the problem either

    _ = try env.doString("(import spork/sh)", "embed");
    _ = try env.doString(
        \\(pp (sh/exec-slurp "uname"))
    , "embed");
    const res = try env.doString(
        \\(sh/exec-slurp "uname")
    , "embed");
    _ = res;
    @breakpoint();
}
