const std = @import("std");

pub const Method = enum {
    hugin_ncc,
    phasecorr_seeded,
    phasecorr_locked,

    pub fn cliName(self: Method) []const u8 {
        return switch (self) {
            .hugin_ncc => "hugin-ncc",
            .phasecorr_seeded => "phasecorr-seeded",
            .phasecorr_locked => "phasecorr-locked",
        };
    }

    pub fn description(self: Method) []const u8 {
        return switch (self) {
            .hugin_ncc => "ported Hugin-style corner detection plus NCC refinement",
            .phasecorr_seeded => "global phase-correlation initializer feeding local NCC refinement",
            .phasecorr_locked => "global phase-correlation initializer with direct locked-offset scoring and seeded fallback",
        };
    }
};

pub fn parseMethod(name: []const u8) ?Method {
    inline for (std.meta.fields(Method)) |field| {
        const method: Method = @enumFromInt(field.value);
        if (std.mem.eql(u8, name, method.cliName())) return method;
    }
    return null;
}
