#!/usr/bin/env julia

module Utils

export concat, files

using DataFrames, CSV

"""
    files(name::Regex; kwargs)

Return all the files in the output folder for the given `location` that
have the given `name`. Optionally specify the Regex for the output folders.

## Arguments
- `name::Regex`: the name of the files
- `location="quantum"`: the location in the output folder. For example
`"classical"` or `"qunatum"`
- `re=r"n[0-9]+-b[0-9]+\\.[0-9]+-d[0-9]+\\.[0-9]+"`: the Regex for the output
folders

"""
function files(name::Regex; location="quantum",
               re=r"n[0-9]+-b[0-9]+\.[0-9]+-d[0-9]+\.[0-9]+")
    prefix = "output/$location/"
    match_list(f) = occursin.(Ref(name), readdir(joinpath(prefix, f)))
    folders = filter(f->occursin(re, f) && any(match_list(f)), readdir(prefix))
    fns = [joinpath.(prefix, f, readdir(joinpath(prefix, f))[match_list(f)])
        for f in folders]
    vcat(fns...)
end

"""
    concat(name::Regex; location="quantum")

Concatenate the `DataFrame`s in the output folder with the given `name`
and return a `DataFrame` containing all the data. See also [`files`](@ref).

## Arguments
- `name::Regex`: the name of the files
- `location="quantum"`: the location in the output folder. For example `"classical"` or `"qunatum"`
- `re=r"n[0-9]+-b[0-9]+\\.[0-9]+-d[0-9]+\\.[0-9]+"`: the Regex for the output
folders

"""
function concat(name::Regex; location="quantum",
                re=r"n[0-9]+-b[0-9]+\.[0-9]+-d[0-9]+\.[0-9]+", filter=:all)
    filenames = files(name; location=location, re=re)

    if (filter == :all)
        df = concat(filenames)
    else
        df = concat(filenames, filter)
    end

    return df
end

function concat(filenames, filter)
    i = 0
    df = DataFrame()
    while !all(haskey.(df, filter))
        i += 1
        df = CSV.read(filenames[i])
    end
    df = df[filter]
    for j=i+1:length(filenames)
        df_ = CSV.read(filenames[j])
        if all(haskey.(df_, filter))
            append!(df, df_[names(df)][filter])
        end
    end

    return df
end

function concat(filenames)
    df = DataFrame()
    df = CSV.read(filenames[1])

    for j=1:length(filenames)
        df_ = CSV.read(filenames[j])
        append!(df, df_[names(df)])
    end

    return df
end

end  # module Utils
