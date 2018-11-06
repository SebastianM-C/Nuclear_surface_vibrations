module Lyapunov

export λproblem, λmap, λ_timeseries_problem, λ_timeseries_map, LyapunovAlgorithm,
    DynSys, TimeRescaling

using ..Distributed
using ..Parameters: @with_kw, @unpack
using ..Hamiltonian
using ..DataBaseInterface
using ..InitialConditions
using ..Classical: AbstractAlgorithm
using ..DInfty: monte_dist
using ..ParallelTrajectories
using ..Custom

using ChaosTools
using Plots, LaTeXStrings
using OrdinaryDiffEq
using DiffEqCallbacks
using RecursiveArrayTools
using StaticArrays
using DataFrames
using LinearAlgebra: norm

abstract type LyapunovAlgorithm <: AbstractAlgorithm end

@with_kw struct DynSys{R <: Real} <: LyapunovAlgorithm  @deftype R
    T = 1e4
    Ttr = 1e3
    d0 = 1e-9
    upper_threshold = 1e-6
    lower_threshold = 1e-12
    dt = 20.
    solver::OrdinaryDiffEqAlgorithm = Vern9()
    diff_eq_kwargs::NamedTuple = (abstol=1e-14, reltol=1e-14, maxiters=1e9)
end

@with_kw struct TimeRescaling{R <: Real} <: LyapunovAlgorithm  @deftype R
    T = 1e4
    Ttr = 1e3
    τ = 5.
    d0 = 1e-9
    solver::OrdinaryDiffEqAlgorithm = Vern9()
    diff_eq_kwargs::NamedTuple = (abstol=1e-14, reltol=1e-14, maxiters=1e9)
end

function build_df(λs, alg)
    N = length(λs)
    # T, Ttr, d0, upper_threshold, lower_threshold, dt, solver, diff_eq_kwargs = unpack_with_nothing(alg)
    @unpack T, Ttr, d0, upper_threshold, lower_threshold, dt, solver, diff_eq_kwargs = alg
    df = DataFrame()
    df[:λs] = categorical(λs)
    df[:lyap_alg] = categorical(fill(string(typeof(alg)), N))
    df[:lyap_T] = categorical(fill(T, N))
    df[:lyap_Ttr] = categorical(fill(Ttr, N))
    df[:lyap_d0] = categorical(fill(d0, N))
    df[:lyap_ut] = categorical(fill(upper_threshold, N))
    df[:lyap_lt] = categorical(fill(lower_threshold, N))
    df[:lyap_dt] = categorical(fill(dt, N))
    df[:lyap_integ] = categorical(fill("$solver", N))
    df[:lyap_diffeq_kw] = categorical(fill("$diff_eq_kwargs", N))
    allowmissing!(df)

    return df
end

function λmap(E; params=PhysicalParameters(), ic_alg=PoincareRand(n=500),
        ic_recompute=false, alg=DynSys(), recompute=false)

    prefix = "output/classical/B$(params.B)-D$(params.D)/E$E"
    q0, p0 = initial_conditions(E, alg=ic_alg, params=params, recompute=ic_recompute)
    db = DataBase(params)
    n, m, border_n = unpack_with_nothing(ic_alg)
    ic_vals = Dict([:n, :m, :E, :initial_cond_alg, :border_n] .=>
                [n, m, E, string(typeof(ic_alg)), border_n])
    ic_cond = compatible(db.df, ic_vals)
    @debug "Initial conditions compat" ic_cond
    # T, Ttr, d0, upper_threshold, lower_threshold, dt, solver, diff_eq_kwargs = unpack_with_nothing(alg)
    @unpack T, Ttr, d0, upper_threshold, lower_threshold, dt, solver, diff_eq_kwargs = alg

    vals = Dict([:lyap_alg, :lyap_T, :lyap_Ttr, :lyap_d0, :lyap_ut,
                :lyap_lt, :lyap_dt, :lyap_integ, :lyap_diffeq_kw] .=>
                [string(typeof(alg)), T, Ttr, d0, upper_threshold,
                lower_threshold, dt, "$solver", "$diff_eq_kwargs"])
    λcond = compatible(db.df, vals)
    cond = ic_cond .& λcond
    @debug "Stored values compat" λcond cond

    if !recompute && count(skipmissing(cond)) == size(q0, 1)
        _cond = BitArray(replace(cond, missing=>false))
        @debug "Loading compatible values."
        λs = unique(db.df[_cond, :λs])
    else
        @debug "Incompatible values. Computing new values."
        λs = λmap(p0, q0, alg; params=params)
        df = build_df(λs, alg)

        if !haskey(db.df, :λs)
            db.df[:λs] = Array{Union{Missing, Float64}}(fill(missing, size(db.df, 1)))
        end

        if size(q0, 1) < count(ic_cond)
            @debug "Removing clones." size(q0, 1) count(ic_cond)
            # then we have to continue with only on set of initial conditions
            # clones can only appear because of a quantity that was computed
            # with different parameters and all the clones have the same size
            if recompute
                ic_cond .&= λcond
            end
            # we will keep only the first clone
            ic_cond = replace(ic_cond[end:-1:1], true=>false,
                count=count(ic_cond)-size(q0, 1))[end:-1:1]

        end

        update!(db, df, ic_cond, vals)

        plt = histogram(λs, nbins=50, xlabel=L"\lambda", ylabel=L"N", label="T = $T")
        fn = string(typeof(alg)) * "_T$T" * "_hist"
        fn = replace(fn, "{Float64}" => "")
        savefig(plt, "$prefix/"*string(typeof(ic_alg))*"/lyapunov_$fn.pdf")
    end
    arr_type = nonnothingtype(eltype(λs))
    # FIXME
    plt = histogram(disallowmissing(Array{arr_type}(λs)), nbins=50, xlabel=L"\lambda", ylabel=L"N", label="T = $T")
    fn = string(typeof(alg)) * "_T$T" * "_hist"
    fn = replace(fn, "{Float64}" => "")
    savefig(plt, "$prefix/"*string(typeof(ic_alg))*"/lyapunov_$fn.pdf")
    return disallowmissing(Array{arr_type}(λs))
end

function λ_timeseries_problem(p0::SVector{N}, q0::SVector{N}, alg::TimeRescaling;
        params=PhysicalParameters()) where {N}
    @unpack T, Ttr, d0, τ, solver, diff_eq_kwargs = alg

    idx1 = SVector{N}(1:N)
    idx2 = SVector{N}(N+1:2N)
    @assert length(p0) == length(q0)

    @inbounds dist(u) =
        norm(vcat(u[1,:][idx1] - u[1,:][idx2], u[2,:][idx1] - u[2,:][idx2]))

    function affect!(integrator)
        a = dist(integrator.u)/d0
        Δp = integrator.u[1,:][idx1] - integrator.u[1,:][idx2]
        Δq = integrator.u[2,:][idx1] - integrator.u[2,:][idx2]
        integrator.u = ArrayPartition(vcat(integrator.u.x[1][idx1],
                                            integrator.u.x[1][idx1] + Δp/a),
                                      vcat(integrator.u.x[2][idx1],
                                            integrator.u.x[2][idx1] + Δq/a))
    end
    rescale = PeriodicCallback(affect!, τ, save_positions=(false, false))
    a = SavedValues(typeof(T), eltype(q0[1]))
    save_func(u, t, integrator) = log(dist(u) / d0)
    sc = SavingCallback(save_func, a, saveat=zero(T):τ:T)
    cs = CallbackSet(sc, rescale)

    if Ttr ≠ 0
        prob_tr = parallel_problem(ṗ, q̇, [p0, p0.+d0/√(2N)], [q0, q0.+d0/√(2N)], Ttr, params)
        sol_tr = solve(prob_tr, solver; diff_eq_kwargs..., save_start=false, save_everystep=false)

        remake(prob_tr, tspan=T, callback=cs, u0=sol_tr[end])
    else
        parallel_problem(ṗ, q̇, [p0, p0.+d0/√(2N)], [q0, q0.+d0/√(2N)], T, params, cs)
    end
end

function λ_timeseries_problem(z0::SVector{N}, alg::TimeRescaling;
        params=PhysicalParameters()) where {N}
    @unpack T, Ttr, d0, τ, solver, diff_eq_kwargs = alg

    idx1 = SVector{N}(1:N)
    idx2 = SVector{N}(N+1:2N)

    @inbounds dist(u) = norm(u[idx1] - u[idx2])

    function affect!(integrator)
        a = dist(integrator.u)/d0
        Δu = integrator.u[idx1] - integrator.u[idx2]
        integrator.u = vcat(integrator.u[idx1], integrator.u[idx1] + Δu/a)
    end
    rescale = PeriodicCallback(affect!, τ, save_positions=(false, false))
    a = SavedValues(typeof(T), eltype(z0[1]))
    save_func(u, t, integrator) = log(dist(u) / d0)
    sc = SavingCallback(save_func, a, saveat=zero(T):τ:T)
    cs = CallbackSet(sc, rescale)

    if Ttr ≠ 0
        prob_tr = parallel_problem(ż, [z0, z0.+d0/√N], Ttr, params)
        sol_tr = solve(prob_tr, solver; diff_eq_kwargs..., save_start=false, save_everystep=false)

        remake(prob_tr, tspan=T, callback=cs, u0=sol_tr[end])
    else
        parallel_problem(ż, [z0, z0.+d0/√N], T, params, cs)
    end
end

function λproblem(z0::SVector{N}, alg::TimeRescaling;
        params=PhysicalParameters()) where {N}
    @unpack T, Ttr, d0, τ, solver, diff_eq_kwargs = alg

    idx1 = SVector{N}(1:N)
    idx2 = SVector{N}(N+1:2N)

    @inbounds dist(u) = norm(u[idx1] - u[idx2])

    function affect!(integrator)
        a = dist(integrator.u) / d0
        Δu = integrator.u[idx1] - integrator.u[idx2]
        integrator.u = vcat(integrator.u[idx1], integrator.u[idx1] + Δu/a)
    end

    function update_λ(affect!, integrator)
        a = dist(integrator.u) / d0
        affect![].saved_value += log(a)
        return nothing
    end

    λcb = ScalarSavingPeriodicCallback(affect!, update_λ, zero(eltype(z0)), τ)

    if Ttr ≠ 0
        prob_tr = parallel_problem(ż, [z0, z0.+d0/√N], Ttr, params)
        sol_tr = solve(prob_tr, solver; diff_eq_kwargs..., save_start=false, save_everystep=false)

        remake(prob_tr, tspan=T, callback=λcb, u0=sol_tr[end])
    else
        parallel_problem(ż, [z0, z0.+d0/√N], T, params, λcb)
    end
end

function λproblem(p0::SVector{N}, q0::SVector{N}, alg::TimeRescaling;
        params=PhysicalParameters()) where {N}
    @unpack T, Ttr, d0, τ, solver, diff_eq_kwargs = alg

    idx1 = SVector{N}(1:N)
    idx2 = SVector{N}(N+1:2N)
    @assert length(p0) == length(q0)

    @inbounds dist(u) =
        norm(vcat(u[1,:][idx1] - u[1,:][idx2], u[2,:][idx1] - u[2,:][idx2]))

    function affect!(integrator)
        a = dist(integrator.u)/d0
        Δp = integrator.u[1,:][idx1] - integrator.u[1,:][idx2]
        Δq = integrator.u[2,:][idx1] - integrator.u[2,:][idx2]
        integrator.u = ArrayPartition(vcat(integrator.u.x[1][idx1],
                                            integrator.u.x[1][idx1] + Δp/a),
                                      vcat(integrator.u.x[2][idx1],
                                            integrator.u.x[2][idx1] + Δq/a))
    end

    function update_λ(affect!, integrator)
        a = dist(integrator.u) / d0
        affect![].saved_value += log(a)
        return nothing
    end

    λcb = ScalarSavingPeriodicCallback(affect!, update_λ, zero(eltype(p0)), τ)

    if Ttr ≠ 0
        prob_tr = parallel_problem(ṗ, q̇, [p0, p0.+d0/√(2N)], [q0, q0.+d0/√(2N)], Ttr, params)
        sol_tr = solve(prob_tr, solver; diff_eq_kwargs..., save_start=false, save_everystep=false)

        remake(prob_tr, tspan=T, callback=λcb, u0=sol_tr[end])
    else
        parallel_problem(ṗ, q̇, [p0, p0.+d0/√(2N)], [q0, q0.+d0/√(2N)], T, params, λcb)
    end
end

function output_λ(sol, i)
    sol.prob.callback.affect!.saved_value / sol.t[end], false
end

function output_λ_timeseries(sol, i)
    a = sol.prob.callback.discrete_callbacks[1].affect!.saved_values
    τ = a.t[2] - a.t[1]
    DiffEqArray([sum(a.saveval[1:i]) / (τ*i) for i in eachindex(a.saveval)], a.t), false
end

function λ_timeseries_map(p0::Array{SVector{N, T}}, q0::Array{SVector{N, T}}, alg::TimeRescaling;
        params=PhysicalParameters(), parallel_type=:none) where {N, T}
    λprob = λproblem(p0[1], q0[1], alg)
    prob_func(prob, i, repeat) = λproblem(p0[i], q0[i], alg)
    monte_prob = MonteCarloProblem(λprob, prob_func=prob_func,
        output_func=output_λ_timeseries)
    sim = solve(monte_prob, alg.solver; alg.diff_eq_kwargs..., num_monte=length(p0),
        save_start=false, save_everystep=false, parallel_type=parallel_type)
end

function λ_timeseries_map(z0::SVector{N, T}, alg::TimeRescaling;
        params=PhysicalParameters(), parallel_type=:none) where {N, T}
    λprob = λproblem(z0[1], alg)
    prob_func(prob, i, repeat) = λproblem(z0[i], alg)
    monte_prob = MonteCarloProblem(λprob, prob_func=prob_func,
        output_func=output_λ_timeseries)
    sim = solve(monte_prob, alg.solver; alg.diff_eq_kwargs..., num_monte=length(z0),
        save_start=false, save_everystep=false, parallel_type=parallel_type)
end

function λ_timeseries_map(p0, q0, alg::TimeRescaling; params::PhysicalParameters)
    p0 = [SVector{2}(p0[i, :]) for i ∈ axes(p0, 1)]
    q0 = [SVector{2}(q0[i, :]) for i ∈ axes(q0, 1)]
    if issplit(alg.solver)
        λ_timeseries_map(p0, q0, alg, params=params, parallel_type=:pmap)
    else
        z0 = [vcat(p0[i], q0[i]) for i ∈ axes(q0, 1)]
        λ_timeseries_map(z0, alg, params=params, parallel_type=:pmap)
    end
end

function λmap(p0::Array{SVector{N, T}}, q0::Array{SVector{N, T}}, alg::TimeRescaling;
        params=PhysicalParameters(), parallel_type=:none) where {N, T}
    λprob = λproblem(p0[1], q0[1], alg)
    prob_func(prob, i, repeat) = λproblem(p0[i], q0[i], alg)
    monte_prob = MonteCarloProblem(λprob, prob_func=prob_func,
        output_func=output_λ)
    sim = solve(monte_prob, alg.solver; alg.diff_eq_kwargs..., num_monte=length(p0),
        save_end=false, save_everystep=false, parallel_type=parallel_type)
end

function λmap(z0::Array{SVector{N, T}}, alg::TimeRescaling;
        params=PhysicalParameters(), parallel_type=:none) where {N, T}
    λprob = λproblem(z0[1], alg)
    prob_func(prob, i, repeat) = λproblem(z0[i], alg)
    monte_prob = MonteCarloProblem(λprob, prob_func=prob_func,
        output_func=output_λ)
    sim = solve(monte_prob, alg.solver; alg.diff_eq_kwargs..., num_monte=length(z0),
        save_end=false, save_everystep=false, parallel_type=parallel_type)
end

function λmap(p0, q0, alg::TimeRescaling; params::PhysicalParameters)
    p0 = [SVector{2}(p0[i, :]) for i ∈ axes(p0, 1)]
    q0 = [SVector{2}(q0[i, :]) for i ∈ axes(q0, 1)]
    λmap(p0, q0, alg, params=params, parallel_type=:pmap).u
end

function λmap(p0, q0, alg::DynSys; params::PhysicalParameters)
    z0 = [SVector{4}(vcat(p0[i, :], q0[i, :])) for i ∈ axes(q0, 1)]
    λmap(z0, alg, params=params)
end

function λmap(z0, alg::DynSys; params=PhysicalParameters())
    @unpack T, Ttr, d0, upper_threshold, lower_threshold, dt, solver, diff_eq_kwargs = alg
    inittest = ChaosTools.inittest_default(4)
    ds = ContinuousDynamicalSystem(ż, z0[1], params)

    pinteg = DynamicalSystemsBase.parallel_integrator(ds,
            [deepcopy(DynamicalSystemsBase.get_state(ds)),
            inittest(DynamicalSystemsBase.get_state(ds), d0)]; alg=solver,
            diff_eq_kwargs...)

    λs = pmap(eachindex(z0)) do i
            reinit!(pinteg, [z0[i], inittest(z0[i], d0)])
            lyapunov(pinteg, T, Ttr, dt, d0, upper_threshold, lower_threshold)
        end

    return λs
end

end  # module Lyapunov
