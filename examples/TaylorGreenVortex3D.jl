# Little LSP hack to get function signatures, go    #src
# to definition etc.                                #src
if isdefined(@__MODULE__, :LanguageServer)          #src
    include("../src/IncompressibleNavierStokes.jl") #src
    using .IncompressibleNavierStokes               #src
end                                                 #src

# # Taylor-Green vortex - 3D
#
# In this example we consider the Taylor-Green vortex.

# We start by loading packages.
# A [Makie](https://github.com/JuliaPlots/Makie.jl) plotting backend is needed
# for plotting. `GLMakie` creates an interactive window (useful for real-time
# plotting), but does not work when building this example on GitHub.
# `CairoMakie` makes high-quality static vector-graphics plots.

#md using CairoMakie
using GLMakie #!md
using IncompressibleNavierStokes

# Case name for saving results
name = "TaylorGreenVortex3D"

# Floating point precision
T = Float64

# For CPU
device = identity

# For GPU (note that `cu` converts to `Float32`)
## using CUDA
## device = cu

# Viscosity model
Re = T(6_000)

# A 3D grid is a Cartesian product of three vectors
n = 32
lims = T(0), T(2π)
x = ntuple(α -> LinRange(lims..., n + 1), 3)
plot_grid(x...)

# Build setup and assemble operators
setup = device(Setup(x; Re));

# Since the grid is uniform and identical for x, y, and z, we may use a
# specialized spectral pressure solver
pressure_solver = SpectralPressureSolver(setup);

# Initial conditions
initial_velocity = (
    (x, y, z) -> sin(x)cos(y)cos(z),
    (x, y, z) -> -cos(x)sin(y)cos(z),
    (x, y, z) -> zero(x),
)
u₀, p₀ = create_initial_conditions(
    setup,
    initial_velocity,
    T(0);
    pressure_solver,
);

GC.gc()
CUDA.reclaim()

# Solve steady state problem
## u, p = solve_steady_state(setup, u₀, p₀; npicard = 6)

# Iteration processors
processors = (
    field_plotter(setup; nupdate = 1),
    ## energy_history_plotter(setup; nupdate = 1),
    ## energy_spectrum_plotter(setup; nupdate = 100),
    ## animator(setup, "vorticity.mp4"; nupdate = 4),
    ## vtk_writer(setup; nupdate = 10, dir = "output/$name", filename = "solution"),
    ## field_saver(setup; nupdate = 10),
    step_logger(; nupdate = 1),
);

# Time interval
t_start, t_end = tlims = T(0), T(5)

# Solve unsteady problem
u, p, outputs = solve_unsteady(
    setup,
    # u₀, p₀,
    u, p,
    tlims;
    Δt = T(0.01),
    processors,
    pressure_solver,
    inplace = true,
);

# ## Post-process
#
# We may visualize or export the computed fields `(u, p)`

# Export to VTK
save_vtk(setup, u, p, "output/solution")

# Plot pressure
plot_pressure(setup, p; levels = 3, alpha = 0.05)

# Plot velocity
plot_velocity(setup, u; levels = 3, alpha = 0.05)

# Plot vorticity
plot_vorticity(setup, u; levels = 5, alpha = 0.05)

# Plot streamfunction
## plot_streamfunction(setup, u)

# Field plot
outputs[1]
