# # Taylor-Green vortex case (TG).
#
# This test case considers the Taylor-Green vortex.

if isdefined(@__MODULE__, :LanguageServer)
    include("../src/IncompressibleNavierStokes.jl")
    using .IncompressibleNavierStokes
end

using IncompressibleNavierStokes
using GLMakie

# Case name for saving results
name = "TGV"

# Floating point type for simulations
T = Float64

## Viscosity model
viscosity_model = LaminarModel{T}(; Re = 1000)
# viscosity_model = KEpsilonModel{T}(; Re = 1000)
# viscosity_model = MixingLengthModel{T}(; Re = 1000)
# viscosity_model = SmagorinskyModel{T}(; Re = 1000)
# viscosity_model = QRModel{T}(; Re = 1000)

## Convection model
convection_model = NoRegConvectionModel{T}()
# convection_model = C2ConvectionModel{T}()
# convection_model = C4ConvectionModel{T}()
# convection_model = LerayConvectionModel{T}()

## Grid
Nx = 20                               # Number of x-volumes
Ny = 20                               # Number of y-volumes
Nz = 20                               # Number of z-volumes
grid = create_grid(
    T,
    Nx,
    Ny,
    Nz;
    xlims = (0, 2π),                  # Horizontal limits (left, right)
    ylims = (0, 2π),                  # Vertical limits (bottom, top)
    zlims = (0, 2π),                  # Depth limits (back, front)
    stretch = (1, 1, 1),              # Stretch factor (sx, sy, sz)
);

## Solver settings
solver_settings = SolverSettings{T}(;
    # pressure_solver = DirectPressureSolver{T}(), # Pressure solver
    # pressure_solver = CGPressureSolver{T}(; maxiter = 500, abstol = 1e-8), # Pressure solver
    pressure_solver = FourierPressureSolver{T}(), # Pressure solver
    p_add_solve = true,              # Additional pressure solve to make it same order as velocity
    abstol = 1e-10,                  # Absolute accuracy
    reltol = 1e-14,                  # Relative accuracy
    maxiter = 10,                    # Maximum number of iterations
    # :no: Replace iteration matrix with I/Δt (no Jacobian)
    # :approximate: Build Jacobian once before iterations only
    # :full: Build Jacobian at each iteration
    newton_type = :full,
)

## Boundary conditions
u_bc(x, y, z, t, setup) = zero(x)
v_bc(x, y, z, t, setup) = zero(x)
w_bc(x, y, z, t, setup) = zero(x)
dudt_bc(x, y, z, t, setup) = zero(x)
dvdt_bc(x, y, z, t, setup) = zero(x)
dwdt_bc(x, y, z, t, setup) = zero(x)
bc = create_boundary_conditions(
    T,
    u_bc,
    v_bc,
    w_bc;
    dudt_bc,
    dvdt_bc,
    dwdt_bc,
    bc_unsteady = false,
    bc_type = (;
        u = (;
            x = (:periodic, :periodic),
            y = (:periodic, :periodic),
            z = (:periodic, :periodic),
        ),
        v = (;
            x = (:periodic, :periodic),
            y = (:periodic, :periodic),
            z = (:periodic, :periodic),
        ),
        w = (;
            x = (:periodic, :periodic),
            y = (:periodic, :periodic),
            z = (:periodic, :periodic),
        ),
        k = (;
            x = (:periodic, :periodic),
            y = (:periodic, :periodic),
            z = (:periodic, :periodic),
        ),
        e = (;
            x = (:periodic, :periodic),
            y = (:periodic, :periodic),
            z = (:periodic, :periodic),
        ),
        ν = (;
            x = (:periodic, :periodic),
            y = (:periodic, :periodic),
            z = (:periodic, :periodic),
        ),
    ),
)

## Forcing parameters
bodyforce_u(x, y, z) = 0
bodyforce_v(x, y, z) = 0
bodyforce_w(x, y, z) = 0
force = SteadyBodyForce{T}(; bodyforce_u, bodyforce_v, bodyforce_w)

## Build setup and assemble operators
setup = Setup{T,3}(; viscosity_model, convection_model, grid, force, solver_settings, bc);
build_operators!(setup);

## Time interval
t_start, t_end = tlims = (0.0, 10.0)

## Initial conditions
initial_velocity_u(x, y, z) = sin(x)cos(y)cos(z)
initial_velocity_v(x, y, z) = -cos(x)sin(y)cos(z)
initial_velocity_w(x, y, z) = zero(z)
# initial_velocity_u(x, y, z) = -sinpi(x)cospi(y)cospi(z)
# initial_velocity_v(x, y, z) = 2cospi(x)sinpi(y)cospi(z)
# initial_velocity_w(x, y, z) = -cospi(x)cospi(y)sinpi(z)
# initial_pressure(x, y, z) = 1 / 4 * (cos(2π * x) + cos(2π * y) + cos(2π * z))
initial_pressure(x, y, z) = 1 / 4 * (cos(2x) + cos(2y) + cos(2z))
V₀, p₀ = create_initial_conditions(
    setup,
    t_start;
    initial_velocity_u,
    initial_velocity_v,
    initial_velocity_w,
    initial_pressure,
);

## Iteration processors
logger = Logger()
real_time_plotter = RealTimePlotter(; nupdate = 10, fieldname = :vorticity)
vtk_writer = VTKWriter(; nupdate = 10, dir = "output/$name", filename = "solution")
tracer = QuantityTracer(; nupdate = 1)
processors = [logger, vtk_writer, tracer]


## Solve steady state problem
problem = SteadyStateProblem(setup, V₀, p₀);
V, p = @time solve(problem; npicard = 6, processors)


## Solve unsteady problem
problem = UnsteadyProblem(setup, V₀, p₀, tlims);
V, p = @time solve(problem, RK44(); Δt = 0.01, processors)


## Post-process
plot_tracers(tracer)
plot_pressure(setup, p)
plot_vorticity(setup, V, tlims[2])
plot_streamfunction(setup, V, tlims[2])