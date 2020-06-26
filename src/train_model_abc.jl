module train_model

export trainmodel

using CSV
using DataFrames
using Dates
using Distributions
using KissABC
using Logging
using YAML

include("abm.jl")  # Depends on: core, config, contacts
using .abm

function trainmodel(configfile::String)
    @info "$(now()) Configuring model"
    d   = YAML.load_file(configfile)
    cfg = Config(d)
    unknowns, n_unknowns = construct_unknowns(d["unknowns"])

    @info "$(now()) Preparing training data"
    y = prepare_training_data(d)

    @info "$(now()) Initialising model"
    params = construct_params(cfg.paramsfile, cfg.demographics.params)
    model  = init_model(params, cfg)

    @info "$(now()) Training model"
    params  = (model, cfg, metrics, unknowns)  # 2nd argument of onerun
    prior   = Factored([Uniform(0.0, 0.05) for i = 1:n_unknowns]...)
    loss    = rmse
    plan    = ABCplan(prior, onerun, y, loss; params=params)
    etarget = d["solver_options"]["etarget"]
    delete!(d["solver_options"], "etarget")
    opts    = Dict{Symbol, Any}(Symbol(k) => v for (k, v) in d["solver_options"])
    res, delta, converged = ABCDE(plan, etarget; opts...)

    @info "$(now()) Extracting result"
    result  = construct_result(res, n_unknowns)  # Vector{NameTuple}
    outfile = joinpath(cfg.output_directory, "trained_params.tsv")
    CSV.write(outfile, result; delim='\t')
    @info "$(now()) Finished"
end

################################################################################
# Construct unknowns

function construct_unknowns(d)
    result     = Dict{Symbol, Any}()
    n_unknowns = format_param_unknowns!(result, 0, d)
    n_unknowns = format_policy_unknowns!(result, n_unknowns, d, "distancing_policy")
    n_unknowns = format_policy_unknowns!(result, n_unknowns, d, "testing_policy")
    n_unknowns = format_policy_unknowns!(result, n_unknowns, d, "tracing_policy")
    n_unknowns = format_policy_unknowns!(result, n_unknowns, d, "quarantine_policy")
    result, n_unknowns
end

function format_param_unknowns!(result, n_unknowns, d)
    if haskey(d, "params")
        result[:params] = Symbol[]
        params = d["params"]
        if params isa String
            n_unknowns += 1
            push!(result[:params], Symbol(params))
        elseif params isa Vector{String}
            for x in params
                n_unknowns += 1
                push!(result[:params], Symbol(x))
            end
        else
            error("Type of unknown params must be String or Vector{String}")
        end
    end
    n_unknowns
end

function format_policy_unknowns!(result, n_unknowns, d, policyname_str::String)
    !haskey(d, policyname_str) && return n_unknowns
    d2 = d[policyname_str]
    isempty(d2) && return n_unknowns
    policyname = Symbol(replace(policyname_str, "_" => ""))  # Example: "distancing_policy" => :distancingpolicy
    result[policyname] = Pair{Date, Vector{Symbol}}[]  # Using a Vector so that order is preserved
    for (dt, flds) in d2
        newvec = Symbol[]
        if flds isa String
            n_unknowns += 1
            push!(newvec, Symbol(flds))
        elseif flds isa Vector{String}
            for fld in flds
                n_unknowns += 1
                push!(newvec, Symbol(fld))
            end
        else
            error("Type of unknown policy elements must be String or Vector{String}")
        end
        push!(result[policyname], Date(dt) => newvec)
    end
    sort!(result[policyname], by = (x) -> x[1])  # Sort by date, earliest to latest. Not necessary but easier to keep track of.
    n_unknowns
end

################################################################################
# Converting from params and policies to theta, and back again.

"Modified: theta"
function params_and_policies_to_theta!(theta, unknowns, cfg, params)
    i = haskey(unknowns, :params)           ? params_to_theta!(theta, 0, unknowns[:params], params) : 0
    i = haskey(unknowns, :distancingpolicy) ? policy_to_theta!(theta, i, unknowns[:distancingpolicy], cfg.t2distancingpolicy) : i
    i = haskey(unknowns, :testingpolicy)    ? policy_to_theta!(theta, i, unknowns[:testingpolicy],    cfg.t2testingpolicy)    : i
    i = haskey(unknowns, :tracingpolicy)    ? policy_to_theta!(theta, i, unknowns[:tracingpolicy],    cfg.t2tracingpolicy)    : i
    i = haskey(unknowns, :quarantinepolicy) ? policy_to_theta!(theta, i, unknowns[:quarantinepolicy], cfg.t2quarantinepolicy) : i
end

"Modified: params, cfg."
function theta_to_params_and_policies!(theta, unknowns, cfg, params)
    i = haskey(unknowns, :params)           ? theta_to_params!(theta, 0, unknowns[:params], params) : 0
    i = haskey(unknowns, :distancingpolicy) ? theta_to_policy!(theta, i, unknowns[:distancingpolicy], cfg.t2distancingpolicy) : i
    i = haskey(unknowns, :testingpolicy)    ? theta_to_policy!(theta, i, unknowns[:testingpolicy],    cfg.t2testingpolicy)    : i
    i = haskey(unknowns, :tracingpolicy)    ? theta_to_policy!(theta, i, unknowns[:tracingpolicy],    cfg.t2tracingpolicy)    : i
    i = haskey(unknowns, :quarantinepolicy) ? theta_to_policy!(theta, i, unknowns[:quarantinepolicy], cfg.t2quarantinepolicy) : i
end

function params_to_theta!(theta, i, unknowns::Vector{Symbol}, params)
    for nm in unknowns
        i += 1
        theta[i] = params[nm]
    end
    i
end

function theta_to_params!(theta, i, unknowns::Vector{Symbol}, params::Dict{Symbol, Float64}, )
    for nm in unknowns
        i += 1
        params[nm] = theta[i]
    end
    i
end

function policy_to_theta!(theta, i, unknowns::Vector{Pair{Date, Vector{Symbol}}}, dt2policy)
    for (dt, flds) in unknowns
        policy = dt2policy[dt]
        for fld in flds
            i += 1
            theta[i] = getfield(policy, fld)
        end
    end
    i
end

function theta_to_policy!(theta, i, unknowns::Vector{Pair{Date, Vector{Symbol}}}, dt2policy)
    for (dt, flds) in unknowns
        policy = dt2policy[dt]
        for fld in flds
            i += 1
            setfield!(policy, fld, theta[i])
        end
    end
    i
end

################################################################################
# Model run

function onerun(theta::T1, params::T2) where {T1 <: NTuple, T2 <: Tuple}
    model, cfg, metrics, unknowns = params
    firstday = cfg.firstday
    lastday  = cfg.lastday
    agents   = model.agents
    theta_to_params_and_policies!(theta, unknowns, cfg, model.params)
    reset_model!(model, cfg)
    reset_metrics!(model)
    prev_npositives = 0
    daterange = firstday:Day(1):lastday
    result    = fill(0, length(daterange) - 1)
    for (i, date) in enumerate(daterange)
        model.date = date
        date == lastday && break
        update_policies!(cfg, date)
        apply_forcing!(cfg.forcing, model, date)
        execute_events!(model.schedule[date], agents, model, date, metrics)

        # Collect result
        npositives = metrics[:positives]
        result[i]  = npositives - prev_npositives
        prev_npositives = npositives
    end
    result
end

################################################################################
# Loss function

function loglikelihood(y, yhat)
    n = size(y, 1)
    result = 0.0
    for i = 1:n
        yhat[i] < 0.01 && continue
        result += y[i] * log(yhat[i]) - yhat[i]  # LL(Y ~ Poisson(yhat)) without constant term
    end
    result / n
end

function rmse(y, yhat)
    n = size(y, 1)
    result = 0.0
    for i = 1:n
        result += abs2(y[i] - yhat[i])
    end
    sqrt(result / n)
end

################################################################################
# Utils

function construct_params(paramsfile::String, demographics_params::Dict{Symbol, Float64})
    tbl    = DataFrame(CSV.File(paramsfile))
    params = Dict{Symbol, Float64}(Symbol(k) => v for (k, v) in zip(tbl.name, tbl.value))
    merge!(params, demographics_params)  # Merge d2 into d1 and return d1 (d1 is enlarged, d2 remains unchanged)
end

"Returns: Vector{Int} containing the number of new cases"
function prepare_training_data(d)
    data      = DataFrame(CSV.File(d["training_data"]))  # Columns: date, newpositives, positives
    date2y    = Dict(date => y for (date, y) in zip(data.date, data.newpositives))
    firstday  = Date(d["firstday"])
    lastday   = Date(d["lastday"])
    daterange = firstday:Day(1):(lastday - Day(1))
    result    = fill(0, length(daterange))
    for (i, date) in enumerate(daterange)
        result[i] = haskey(date2y, date) ? date2y[date] : 0
    end
    result
end

function construct_result(res, n_unknowns)
    result = NamedTuple{(:name, :p025, :p25, :p50, :p75, :p975), Tuple{String, Float64, Float64, Float64, Float64, Float64}}[]
    for i = 1:n_unknowns
        p   = getindex.(res, i)
        nm  = "x$(i)"  # TODO: Fix
        row = (name=nm, p025=quantile(p, 0.025), p25=quantile(p, 0.25), p50=quantile(p, 0.5), p75=quantile(p, 0.75), p975=quantile(p, 0.975))
        push!(result, row)
    end
    result
end

end