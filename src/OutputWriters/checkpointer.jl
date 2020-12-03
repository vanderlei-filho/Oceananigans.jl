using Glob
import Oceananigans.Fields: set!

using Oceananigans.Fields: offset_data

"""
    Checkpointer{I, T, P} <: AbstractOutputWriter

An output writer for checkpointing models to a JLD2 file from which models can be restored.
"""
mutable struct Checkpointer{T, P} <: AbstractOutputWriter
      schedule :: T
           dir :: String
        prefix :: String
    properties :: P
         force :: Bool
       verbose :: Bool
end

"""
    Checkpointer(model; schedule,
                        dir = ".",
                     prefix = "checkpoint",
                      force = false,
                    verbose = false,
                 properties = [:architecture, :boundary_conditions, :grid, :clock, :coriolis,
                               :buoyancy, :closure, :velocities, :tracers, :timestepper]
                 )

Construct a `Checkpointer` that checkpoints the model to a JLD2 file every so often as
specified by `schedule`. The `model.clock.iteration` is included
in the filename to distinguish between multiple checkpoint files.

Note that extra model `properties` can be safely specified, but removing crucial properties
such as `:velocities` will make restoring from the checkpoint impossible.

The checkpoint file is generated by serializing model properties to JLD2. However,
functions cannot be serialized to disk with JLD2. So if a model property
contains a reference somewhere in its hierarchy it will not be included in the checkpoint
file (and you will have to manually restore them).

Keyword arguments
=================
- `schedule` (required): Schedule that determines when to checkpoint.

- `dir`: Directory to save output to. Default: "." (current working directory).

- `prefix`: Descriptive filename prefixed to all output files. Default: "checkpoint".

- `force`: Remove existing files if their filenames conflict. Default: `false`.

- `verbose`: Log what the output writer is doing with statistics on compute/write times
             and file sizes. Default: `false`.

- `properties`: List of model properties to checkpoint. Some are required.
"""
function Checkpointer(model; schedule,
                             dir = ".",
                          prefix = "checkpoint",
                           force = false,
                         verbose = false,
                      properties = [:architecture, :grid, :clock, :coriolis,
                                    :buoyancy, :closure, :velocities, :tracers,
                                    :timestepper, :particles]
                     )

    # Certain properties are required for `restore_from_checkpoint` to work.
    required_properties = (:grid, :architecture, :velocities, :tracers, :timestepper, :particles)

    for rp in required_properties
        if rp ∉ properties
            @warn "$rp is required for checkpointing. It will be added to checkpointed properties"
            push!(properties, rp)
        end
    end

    for p in properties
        p isa Symbol || error("Property $p to be checkpointed must be a Symbol.")
        p ∉ propertynames(model) && error("Cannot checkpoint $p, it is not a model property!")

        if has_reference(Function, getproperty(model, p)) && (p ∉ required_properties)
            @warn "model.$p contains a function somewhere in its hierarchy and will not be checkpointed."
            filter!(e -> e != p, properties)
        end
    end

    mkpath(dir)

    return Checkpointer(schedule, dir, prefix, properties, force, verbose)
end

""" Returns the full prefix (the `superprefix`) associated with `checkpointer`. """
checkpoint_superprefix(prefix) = prefix * "_iteration"

"""
    checkpoint_path(iteration::Int, c::Checkpointer)

Returns the path to the `c`heckpointer file associated with model `iteration`.
"""
checkpoint_path(iteration::Int, c::Checkpointer) =
    joinpath(c.dir, string(checkpoint_superprefix(c.prefix), iteration, ".jld2"))

function write_output!(c::Checkpointer, model)
    filepath = checkpoint_path(model.clock.iteration, c)
    c.verbose && @info "Checkpointing to file $filepath..."

    t1 = time_ns()
    jldopen(filepath, "w") do file
        file["checkpointed_properties"] = c.properties
        serializeproperties!(file, model, c.properties)
    end

    t2, sz = time_ns(), filesize(filepath)
    c.verbose && @info "Checkpointing done: time=$(prettytime((t2-t1)/1e9)), size=$(pretty_filesize(sz))"
end

# This is the default name used in the simulation.output_writers ordered dict.
defaultname(::Checkpointer, nelems) = :checkpointer

function restore_if_not_missing(file, address)
    if !ismissing(file[address])
        return file[address]
    else
        @warn "Checkpoint file does not contain $address. Returning missing. " *
              "You might need to restore $address manually."
        return missing
    end
end

function restore_field(file, address, arch, grid, loc, kwargs)
    field_address = file[address * "/location"]
    data = offset_data(convert_to_arch(arch, file[address * "/data"]), grid, loc)

    # Extract field name from address. We use 2:end so "tracers/T "gets extracted
    # as :T while "timestepper/Gⁿ/T" gets extracted as :Gⁿ/T (we don't want to
    # apply the same BCs on T and T tendencies).
    field_name = split(address, "/")[2:end] |> join |> Symbol

    # If the user specified a non-default boundary condition through the kwargs
    # in restore_from_checkpoint, then use them when restoring the field. Otherwise
    # restore the BCs from the checkpoint file as long as they're not missing.
    if :boundary_conditions in keys(kwargs) && field_name in keys(kwargs[:boundary_conditions])
        bcs = kwargs[:boundary_conditions][field_name]
    else
        bcs = restore_if_not_missing(file, address * "/boundary_conditions")
    end

    return Field(field_address, arch, grid, bcs, data)
end

const u_location = (Face, Cell, Cell)
const v_location = (Cell, Face, Cell)
const w_location = (Cell, Cell, Face)
const c_location = (Cell, Cell, Cell)

"""
    restore_from_checkpoint(filepath; kwargs=Dict())

Restore a model from the checkpoint file stored at `filepath`. `kwargs` can be passed
to the model constructor, which can be especially useful if you need to manually
restore forcing functions or boundary conditions that rely on functions.
"""
function restore_from_checkpoint(filepath; kwargs...)
    kwargs = length(kwargs) == 0 ? Dict{Symbol,Any}() : Dict{Symbol,Any}(kwargs)

    file = jldopen(filepath, "r")
    cps = file["checkpointed_properties"]

    if haskey(kwargs, :architecture)
        arch = kwargs[:architecture]
        filter!(p -> p ≠ :architecture, cps)
    else
        arch = file["architecture"]
    end

    grid = file["grid"]

    # Restore velocity fields
    kwargs[:velocities] = (u = restore_field(file, "velocities/u", arch, grid, u_location, kwargs),
                           v = restore_field(file, "velocities/v", arch, grid, v_location, kwargs),
                           w = restore_field(file, "velocities/w", arch, grid, w_location, kwargs))

    filter!(p -> p ≠ :velocities, cps) # pop :velocities from checkpointed properties

    # Restore tracer fields
    tracer_names         = Tuple(Symbol.(keys(file["tracers"])))
    tracer_fields        = Tuple(restore_field(file, "tracers/$c", arch, grid, c_location, kwargs) for c in tracer_names)
    tracer_fields_kwargs = NamedTuple{tracer_names}(tracer_fields)

    kwargs[:tracers] = TracerFields(tracer_names, arch, grid; tracer_fields_kwargs...)

    filter!(p -> p ≠ :tracers, cps) # pop :tracers from checkpointed properties

    # Restore time stepper tendency fields
    field_names = (:u, :v, :w, tracer_names...) # field names
    locs = (u_location, v_location, w_location, Tuple(c_location for c in tracer_names)...) # name locations

    G⁻_fields = Tuple(restore_field(file, "timestepper/G⁻/$(field_names[i])", arch, grid, locs[i], kwargs) for i = 1:length(field_names))
    Gⁿ_fields = Tuple(restore_field(file, "timestepper/Gⁿ/$(field_names[i])", arch, grid, locs[i], kwargs) for i = 1:length(field_names))

    G⁻_tendency_field_kwargs = NamedTuple{field_names}(G⁻_fields)
    Gⁿ_tendency_field_kwargs = NamedTuple{field_names}(Gⁿ_fields)

    # Restore time stepper
    kwargs[:timestepper] =
        QuasiAdamsBashforth2TimeStepper(arch, grid, tracer_names;
                                        G⁻ = TendencyFields(arch, grid, tracer_names; G⁻_tendency_field_kwargs...),
                                        Gⁿ = TendencyFields(arch, grid, tracer_names; Gⁿ_tendency_field_kwargs...))

    filter!(p -> p ≠ :timestepper, cps) # pop :timestepper from checkpointed properties

    # Restore the remaining checkpointed properties
    for p in cps
        if !haskey(kwargs, p)
            kwargs[p] = file["$p"]
        end
    end

    close(file)

    model = IncompressibleModel(; kwargs...)

    return model
end

#####
##### set! for checkpointer filepaths
#####

"""
    set!(model, filepath::AbstractString)

Set data in `model.velocities`, `model.tracers`, `model.timestepper.Gⁿ`, and
`model.timestepper.G⁻` to checkpointed data stored at `filepath`.
"""
function set!(model, filepath::AbstractString)

    jldopen(filepath, "r") do file

        # Validate the grid
        checkpointed_grid = file["grid"]
        model.grid == checkpointed_grid ||
            error("The grid associated with $filepath and model.grid are not the same!")

        # Set model fields and tendency fields
        model_fields = merge(model.velocities, model.tracers)

        for name in propertynames(model_fields)
            # Load data for each model field
            address = name ∈ (:u, :v, :w) ? "velocities/$name" : "tracers/$name"
            parent_data = file[address * "/data"]

            model_field = model_fields[name]
            copyto!(model_field.data.parent, parent_data)

            # Load tendency data
            #
            # Note: this step is unecessary for models that use RungeKutta3TimeStepper and
            # tendency restoration could be depcrecated in the future.

            # Tendency "n"
            parent_data = file["timestepper/Gⁿ/$name/data"]

            tendencyⁿ_field = model.timestepper.Gⁿ[name]
            copyto!(tendencyⁿ_field.data.parent, parent_data)

            # Tendency "n-1"
            parent_data = file["timestepper/G⁻/$name/data"]

            tendency⁻_field = model.timestepper.G⁻[name]
            copyto!(tendency⁻_field.data.parent, parent_data)
        end

        copyto!(model.particles.particles, file["particles"])

        checkpointed_clock = file["clock"]

        # Update model clock
        model.clock.iteration = checkpointed_clock.iteration
        model.clock.time = checkpointed_clock.time

    end

    return nothing
end
