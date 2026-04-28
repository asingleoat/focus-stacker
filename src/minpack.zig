const std = @import("std");
const profiler = @import("profiler.zig");

pub const Params = struct {
    ftol: f64,
    xtol: f64,
    gtol: f64,
    maxfev: usize,
    epsfcn: f64,
    factor: f64,
};

pub const Result = struct {
    info: i32,
    nfev: usize,
};

const machep: f64 = std.math.floatEps(f64);
const dwarf: f64 = std.math.floatMin(f64);

pub fn lmdif(
    comptime Context: type,
    allocator: std.mem.Allocator,
    ctx: *Context,
    evalFn: *const fn (*Context, []const f64, []f64) anyerror!void,
    x: []f64,
    m: usize,
    params: Params,
) !Result {
    const prof = profiler.scope("minpack.lmdif");
    defer prof.end();

    const n = x.len;
    if (n == 0 or m < n) return .{ .info = 0, .nfev = 0 };

    const fvec = try allocator.alloc(f64, m);
    defer allocator.free(fvec);
    const diag = try allocator.alloc(f64, n);
    defer allocator.free(diag);
    const qtf = try allocator.alloc(f64, n);
    defer allocator.free(qtf);
    const wa1 = try allocator.alloc(f64, n);
    defer allocator.free(wa1);
    const wa2 = try allocator.alloc(f64, n);
    defer allocator.free(wa2);
    const wa3 = try allocator.alloc(f64, n);
    defer allocator.free(wa3);
    const wa4 = try allocator.alloc(f64, m);
    defer allocator.free(wa4);
    const ipvt = try allocator.alloc(usize, n);
    defer allocator.free(ipvt);
    const fjac = try allocator.alloc(f64, m * n);
    defer allocator.free(fjac);

    @memset(diag, 0.0);
    @memset(qtf, 0.0);
    @memset(wa1, 0.0);
    @memset(wa2, 0.0);
    @memset(wa3, 0.0);
    @memset(wa4, 0.0);
    @memset(fjac, 0.0);
    @memset(ipvt, 0);

    try evalFn(ctx, x, fvec);
    var nfev: usize = 1;
    var fnorm = enorm(fvec);
    var par: f64 = 0.0;
    var iter: usize = 1;
    var delta: f64 = 1.0e-4;
    var xnorm: f64 = 1.0e-4;

    while (true) {
        {
            const iter_prof = profiler.scope("minpack.lmdif.outer_iteration");
            defer iter_prof.end();

            try fdjac2(Context, ctx, evalFn, x, fvec, fjac, m, n, params.epsfcn, wa4);
            nfev += n;

            qrfac(fjac, m, n, true, ipvt, wa1, wa2, wa3);

            if (iter == 1) {
                for (0..n) |j| {
                    diag[j] = if (wa2[j] == 0.0) 1.0 else wa2[j];
                    wa3[j] = diag[j] * x[j];
                }
                xnorm = enorm(wa3);
                delta = params.factor * xnorm;
                if (delta == 0.0) delta = params.factor;
            } else {
                for (0..n) |j| {
                    diag[j] = @max(diag[j], wa2[j]);
                    wa2[j] = diag[j] * x[j];
                }
                xnorm = enorm(wa2);
            }

            for (0..m) |i| wa4[i] = fvec[i];
            for (0..n) |j| {
                const diag_index = index(m, j, j);
                const temp3 = fjac[diag_index];
                if (temp3 != 0.0) {
                    var sum: f64 = 0.0;
                    for (j..m) |i| {
                        sum += fjac[index(m, i, j)] * wa4[i];
                    }
                    const temp = -sum / temp3;
                    for (j..m) |i| {
                        wa4[i] += fjac[index(m, i, j)] * temp;
                    }
                }
                fjac[diag_index] = wa1[j];
                qtf[j] = wa4[j];
            }

            var gnorm: f64 = 0.0;
            if (fnorm != 0.0) {
                for (0..n) |j| {
                    const l = ipvt[j];
                    if (wa2[l] != 0.0) {
                        var sum: f64 = 0.0;
                        for (0..j + 1) |i| {
                            sum += fjac[index(m, i, j)] * (qtf[i] / fnorm);
                        }
                        gnorm = @max(gnorm, @abs(sum / wa2[l]));
                    }
                }
            }
            if (gnorm <= params.gtol) {
                return .{ .info = 4, .nfev = nfev };
            }

            while (true) {
                {
                    const trial_prof = profiler.scope("minpack.lmdif.trial_step");
                    defer trial_prof.end();

                    try lmpar(allocator, fjac, m, n, ipvt, diag, qtf, delta, &par, wa1, wa2, wa3, wa4);

                    for (0..n) |j| {
                        wa1[j] = -wa1[j];
                        wa2[j] = x[j] + wa1[j];
                        wa3[j] = diag[j] * wa1[j];
                    }
                    const pnorm = enorm(wa3);
                    if (iter == 1) {
                        delta = @min(delta, pnorm);
                    }

                    try evalFn(ctx, wa2, wa4);
                    nfev += 1;
                    const fnorm1 = enorm(wa4);

                    var actred: f64 = -1.0;
                    if (0.1 * fnorm1 < fnorm) {
                        const temp = fnorm1 / fnorm;
                        actred = 1.0 - temp * temp;
                    }

                    @memset(wa3, 0.0);
                    for (0..n) |j| {
                        const l = ipvt[j];
                        const temp = wa1[l];
                        for (0..j + 1) |i| {
                            wa3[i] += fjac[index(m, i, j)] * temp;
                        }
                    }

                    const temp1 = enorm(wa3) / fnorm;
                    const temp2 = (@sqrt(par) * pnorm) / fnorm;
                    const prered = temp1 * temp1 + (temp2 * temp2) / 0.5;
                    const dirder = -(temp1 * temp1 + temp2 * temp2);
                    const ratio = if (prered != 0.0) actred / prered else 0.0;

                    if (ratio <= 0.25) {
                        var temp: f64 = 0.5;
                        if (actred < 0.0) {
                            temp = 0.5 * dirder / (dirder + 0.5 * actred);
                        }
                        if (0.1 * fnorm1 >= fnorm or temp < 0.1) temp = 0.1;
                        delta = temp * @min(delta, pnorm / 0.1);
                        par /= temp;
                    } else if (par == 0.0 or ratio >= 0.75) {
                        delta = pnorm / 0.5;
                        par *= 0.5;
                    }

                    if (ratio >= 1.0e-4) {
                        @memcpy(x, wa2);
                        @memcpy(fvec, wa4);
                        fnorm = fnorm1;
                        for (0..n) |j| wa2[j] = diag[j] * x[j];
                        xnorm = enorm(wa2);
                        iter += 1;
                    }

                    const info1 = @abs(actred) <= params.ftol and prered <= params.ftol and 0.5 * ratio <= 1.0;
                    const info2 = delta <= params.xtol * xnorm;
                    if (info1 and info2) return .{ .info = 3, .nfev = nfev };
                    if (info1) return .{ .info = 1, .nfev = nfev };
                    if (info2) return .{ .info = 2, .nfev = nfev };
                    if (nfev >= params.maxfev) return .{ .info = 5, .nfev = nfev };
                    if (@abs(actred) <= machep and prered <= machep and 0.5 * ratio <= 1.0) return .{ .info = 6, .nfev = nfev };
                    if (delta <= machep * xnorm) return .{ .info = 7, .nfev = nfev };
                    if (gnorm <= machep) return .{ .info = 8, .nfev = nfev };
                    if (ratio >= 1.0e-4) break;
                }
            }
        }
    }
}

fn fdjac2(
    comptime Context: type,
    ctx: *Context,
    evalFn: *const fn (*Context, []const f64, []f64) anyerror!void,
    x: []f64,
    fvec: []const f64,
    fjac: []f64,
    m: usize,
    n: usize,
    epsfcn: f64,
    wa: []f64,
) !void {
    const prof = profiler.scope("minpack.fdjac2");
    defer prof.end();

    const eps = @sqrt(@max(epsfcn, machep));
    for (0..n) |j| {
        const temp = x[j];
        var h = eps * @abs(temp);
        if (h == 0.0) h = eps;
        x[j] = temp + h;
        try evalFn(ctx, x, wa);
        x[j] = temp;
        for (0..m) |i| {
            fjac[index(m, i, j)] = (wa[i] - fvec[i]) / h;
        }
    }
}

fn qrfac(a: []f64, m: usize, n: usize, pivot: bool, ipvt: []usize, rdiag: []f64, acnorm: []f64, wa: []f64) void {
    const prof = profiler.scope("minpack.qrfac");
    defer prof.end();

    for (0..n) |j| {
        acnorm[j] = enormColumn(a, m, j, 0);
        rdiag[j] = acnorm[j];
        wa[j] = rdiag[j];
        if (pivot) ipvt[j] = j;
    }

    const minmn = @min(m, n);
    for (0..minmn) |j| {
        if (pivot) {
            var kmax = j;
            for (j..n) |k| {
                if (rdiag[k] > rdiag[kmax]) kmax = k;
            }
            if (kmax != j) {
                for (0..m) |i| {
                    const a_idx = index(m, i, j);
                    const b_idx = index(m, i, kmax);
                    const temp = a[a_idx];
                    a[a_idx] = a[b_idx];
                    a[b_idx] = temp;
                }
                std.mem.swap(f64, &rdiag[kmax], &rdiag[j]);
                std.mem.swap(f64, &wa[kmax], &wa[j]);
                std.mem.swap(usize, &ipvt[j], &ipvt[kmax]);
            }
        }

        const diag_index = index(m, j, j);
        var ajnorm = enormColumn(a, m, j, j);
        if (ajnorm == 0.0) {
            rdiag[j] = -ajnorm;
            continue;
        }
        if (a[diag_index] < 0.0) ajnorm = -ajnorm;
        for (j..m) |i| a[index(m, i, j)] /= ajnorm;
        a[diag_index] += 1.0;

        const jp1 = j + 1;
        if (jp1 < n) {
            for (jp1..n) |k| {
                var sum: f64 = 0.0;
                for (j..m) |i| {
                    sum += a[index(m, i, j)] * a[index(m, i, k)];
                }
                const temp = sum / a[diag_index];
                for (j..m) |i| {
                    a[index(m, i, k)] -= temp * a[index(m, i, j)];
                }
                if (pivot and rdiag[k] != 0.0) {
                    var temp2 = a[index(m, j, k)] / rdiag[k];
                    temp2 = @max(0.0, 1.0 - temp2 * temp2);
                    rdiag[k] *= @sqrt(temp2);
                    temp2 = rdiag[k] / wa[k];
                    if (0.05 * temp2 * temp2 <= machep) {
                        rdiag[k] = enormColumn(a, m, k, jp1);
                        wa[k] = rdiag[k];
                    }
                }
            }
        }
        rdiag[j] = -ajnorm;
    }
}

fn lmpar(
    allocator: std.mem.Allocator,
    r: []f64,
    ldr: usize,
    n: usize,
    ipvt: []const usize,
    diag: []const f64,
    qtb: []const f64,
    delta: f64,
    par: *f64,
    x: []f64,
    sdiag: []f64,
    wa1: []f64,
    wa2: []f64,
) !void {
    const prof = profiler.scope("minpack.lmpar");
    defer prof.end();

    _ = allocator;
    var nsing = n;
    {
        const phase_prof = profiler.scope("minpack.lmpar.gauss_newton");
        defer phase_prof.end();

        for (0..n) |j| {
            wa1[j] = qtb[j];
            if (r[index(ldr, j, j)] == 0.0 and nsing == n) nsing = j;
            if (nsing < n) wa1[j] = 0.0;
        }

        if (nsing >= 1) {
            var k: usize = 0;
            while (k < nsing) : (k += 1) {
                const j = nsing - k - 1;
                wa1[j] /= r[index(ldr, j, j)];
                const temp = wa1[j];
                if (j > 0) {
                    for (0..j) |i| {
                        wa1[i] -= r[index(ldr, i, j)] * temp;
                    }
                }
            }
        }
    }
    for (0..n) |j| x[ipvt[j]] = wa1[j];

    for (0..n) |j| wa2[j] = diag[j] * x[j];
    const dxnorm = enorm(wa2);
    var fp = dxnorm - delta;
    if (fp <= 0.1 * delta) {
        par.* = 0.0;
        return;
    }

    var parl: f64 = 0.0;
    var gnorm: f64 = 0.0;
    var paru: f64 = 0.0;
    {
        const phase_prof = profiler.scope("minpack.lmpar.bounds");
        defer phase_prof.end();

        if (nsing >= n) {
            for (0..n) |j| {
                const l = ipvt[j];
                wa1[j] = diag[l] * (wa2[l] / dxnorm);
            }
            for (0..n) |j| {
                var sum: f64 = 0.0;
                for (0..j) |i| sum += r[index(ldr, i, j)] * wa1[i];
                wa1[j] = (wa1[j] - sum) / r[index(ldr, j, j)];
            }
            const temp = enorm(wa1);
            parl = ((fp / delta) / temp) / temp;
        }

        for (0..n) |j| {
            var sum: f64 = 0.0;
            for (0..j + 1) |i| sum += r[index(ldr, i, j)] * qtb[i];
            const l = ipvt[j];
            wa1[j] = sum / diag[l];
        }
        gnorm = enorm(wa1);
        paru = gnorm / delta;
        if (paru == 0.0) paru = dwarf / @min(delta, 0.1);
    }

    par.* = @max(par.*, parl);
    par.* = @min(par.*, paru);
    if (par.* == 0.0) par.* = gnorm / dxnorm;

    var iter: usize = 0;
    while (true) {
        {
            const iter_prof = profiler.scope("minpack.lmpar.iteration");
            defer iter_prof.end();

            iter += 1;
            if (par.* == 0.0) par.* = @max(dwarf, 0.001 * paru);
            const temp = @sqrt(par.*);
            for (0..n) |j| wa1[j] = temp * diag[j];
            const dxnorm_iter = blk: {
                const phase_prof = profiler.scope("minpack.lmpar.qrsolv_eval");
                defer phase_prof.end();

                qrsolv(r, ldr, n, ipvt, wa1, qtb, x, sdiag, wa2);
                for (0..n) |j| wa2[j] = diag[j] * x[j];
                break :blk enorm(wa2);
            };
            const prev_fp = fp;
            fp = dxnorm_iter - delta;
            if (@abs(fp) <= 0.1 * delta or (parl == 0.0 and fp <= prev_fp and prev_fp < 0.0) or iter == 10) {
                return;
            }

            const parc = blk: {
                const phase_prof = profiler.scope("minpack.lmpar.correction");
                defer phase_prof.end();

                for (0..n) |j| {
                    const l = ipvt[j];
                    wa1[j] = diag[l] * (wa2[l] / dxnorm_iter);
                }
                for (0..n) |j| {
                    wa1[j] /= sdiag[j];
                    const temp2 = wa1[j];
                    const jp1 = j + 1;
                    if (jp1 < n) {
                        for (jp1..n) |i| wa1[i] -= r[index(ldr, i, j)] * temp2;
                    }
                }
                const temp3 = enorm(wa1);
                break :blk ((fp / delta) / temp3) / temp3;
            };
            if (fp > 0.0) parl = @max(parl, par.*);
            if (fp < 0.0) paru = @min(paru, par.*);
            par.* = @max(parl, par.* + parc);
        }
    }
}

fn qrsolv(r: []f64, ldr: usize, n: usize, ipvt: []const usize, diag: []const f64, qtb: []const f64, x: []f64, sdiag: []f64, wa: []f64) void {
    const prof = profiler.scope("minpack.qrsolv");
    defer prof.end();

    {
        const phase_prof = profiler.scope("minpack.qrsolv.copy_r");
        defer phase_prof.end();

        for (0..n) |j| {
            for (j..n) |i| {
                r[index(ldr, i, j)] = r[index(ldr, j, i)];
            }
            x[j] = r[index(ldr, j, j)];
            wa[j] = qtb[j];
        }
    }

    {
        const phase_prof = profiler.scope("minpack.qrsolv.eliminate_diag");
        defer phase_prof.end();

        for (0..n) |j| {
            const l = ipvt[j];
            if (diag[l] == 0.0) continue;
            @memset(sdiag[j..], 0.0);
            sdiag[j] = diag[l];
            var qtbpj: f64 = 0.0;
            for (j..n) |k| {
                if (sdiag[k] == 0.0) continue;
                const kk = index(ldr, k, k);
                var sin_: f64 = 0.0;
                var cos_: f64 = 0.0;
                if (@abs(r[kk]) < @abs(sdiag[k])) {
                    const cotan = r[kk] / sdiag[k];
                    sin_ = 0.5 / @sqrt(0.25 + 0.25 * cotan * cotan);
                    cos_ = sin_ * cotan;
                } else {
                    const tan_ = sdiag[k] / r[kk];
                    cos_ = 0.5 / @sqrt(0.25 + 0.25 * tan_ * tan_);
                    sin_ = cos_ * tan_;
                }

                r[kk] = cos_ * r[kk] + sin_ * sdiag[k];
                const temp = cos_ * wa[k] + sin_ * qtbpj;
                qtbpj = -sin_ * wa[k] + cos_ * qtbpj;
                wa[k] = temp;

                const kp1 = k + 1;
                if (kp1 < n) {
                    for (kp1..n) |i| {
                        const temp2 = cos_ * r[index(ldr, i, k)] + sin_ * sdiag[i];
                        sdiag[i] = -sin_ * r[index(ldr, i, k)] + cos_ * sdiag[i];
                        r[index(ldr, i, k)] = temp2;
                    }
                }
            }
            sdiag[j] = r[index(ldr, j, j)];
            r[index(ldr, j, j)] = x[j];
        }
    }

    {
        const phase_prof = profiler.scope("minpack.qrsolv.backsolve");
        defer phase_prof.end();

        var nsing = n;
        for (0..n) |j| {
            if (sdiag[j] == 0.0 and nsing == n) nsing = j;
            if (nsing < n) wa[j] = 0.0;
        }
        if (nsing >= 1) {
            var k: usize = 0;
            while (k < nsing) : (k += 1) {
                const j = nsing - k - 1;
                var sum: f64 = 0.0;
                const jp1 = j + 1;
                if (jp1 < nsing) {
                    for (jp1..nsing) |i| sum += r[index(ldr, i, j)] * wa[i];
                }
                wa[j] = (wa[j] - sum) / sdiag[j];
            }
        }
        for (0..n) |j| x[ipvt[j]] = wa[j];
    }
}

fn enorm(values: []const f64) f64 {
    const rdwarf = 3.834e-20;
    const rgiant = 1.304e19;
    var s1: f64 = 0.0;
    var s2: f64 = 0.0;
    var s3: f64 = 0.0;
    var x1max: f64 = 0.0;
    var x3max: f64 = 0.0;
    const agiant = rgiant / @as(f64, @floatFromInt(values.len));

    for (values) |value| {
        const xabs = @abs(value);
        if (xabs > rdwarf and xabs < agiant) {
            s2 += xabs * xabs;
        } else if (xabs > rdwarf) {
            if (xabs > x1max) {
                const temp = x1max / xabs;
                s1 = 1.0 + s1 * temp * temp;
                x1max = xabs;
            } else {
                const temp = xabs / x1max;
                s1 += temp * temp;
            }
        } else if (xabs > x3max) {
            const temp = x3max / xabs;
            s3 = 1.0 + s3 * temp * temp;
            x3max = xabs;
        } else if (xabs != 0.0) {
            const temp = xabs / x3max;
            s3 += temp * temp;
        }
    }

    if (s1 != 0.0) {
        const temp = s1 + (s2 / x1max) / x1max;
        return x1max * @sqrt(temp);
    }
    if (s2 != 0.0) {
        const temp = if (s2 >= x3max)
            s2 * (1.0 + (x3max / s2) * (x3max * s3))
        else
            x3max * ((s2 / x3max) + (x3max * s3));
        return @sqrt(temp);
    }
    return x3max * @sqrt(s3);
}

fn enormColumn(a: []const f64, m: usize, column: usize, start_row: usize) f64 {
    return enorm(a[index(m, start_row, column)..index(m, m, column)]);
}

inline fn index(rows: usize, row: usize, col: usize) usize {
    return row + rows * col;
}
