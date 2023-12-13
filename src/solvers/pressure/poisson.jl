"""
    poisson(solver, f)

Solve the Poisson equation for the pressure with right hand side `f` at time `t`.
For periodic and no-slip BC, the sum of `f` should be zero.

Non-mutating/allocating/out-of-place version.

See also [`poisson!`](@ref).
"""
function poisson end

poisson(solver, f) = poisson!(solver, zero(f), f)

"""
    poisson!(solver, p, f)

Solve the Poisson equation for the pressure with right hand side `f` at time `t`.
For periodic and no-slip BC, the sum of `f` should be zero.

Mutating/non-allocating/in-place version.

See also [`poisson`](@ref).
"""
function poisson! end

function poisson!(solver::DirectPressureSolver, p, f)
    (; setup, fact) = solver
    (; Ip) = setup.grid
    T = eltype(p)
    # solver.f .= view(view(f, Ip), :)
    # copyto!(solver.f, view(view(f, Ip), :))
    pp = view(view(p, Ip), :)
    if false # p isa CuArray 
        ldiv!(solver.p, fact, solver.f)
    elseif false # p isa CuArray
        copyto!(view(solver.f, 1:length(solver.f)-1), view(view(f, Ip), :))
        F = fact
        a, b = solver.f, solver.p
        # solver.p .= F.Q * (F.U \ (F.L \ (F.P * (F.Rs .* solver.f))))
        # copyto!(pp, view(solver.p, 1:length(solver.p)-1))
        a .*= F.Rs
        mul!(b, F.P, a)
        ldiv!(a, F.L, b)
        ldiv!(b, F.U, a)
        mul!(a, F.Q, b)
        copyto!(pp, view(a, 1:length(a)-1))
    else
        copyto!(view(solver.f, 1:length(solver.f)-1), Array(view(view(f, Ip), :)))
        solver.p .= fact \ solver.f
        copyto!(pp, T.(view(solver.p, 1:length(solver.p)-1)))
    end
    # @infiltrate
    # ldiv!(solver.p, fact, solver.f)
    # pp .= solver.p
    # copyto!(pp, solver.p)
    p
end

function poisson!(solver::CGMatrixPressureSolver, p, f)
    (; L, qin, qout, abstol, reltol, maxiter) = solver
    copyto!(qin, view(view(f, Ip), :))
    p = view(p, :)
    cg!(qout, L, qin; abstol, reltol, maxiter)
    copyto!(view(view(p, Ip), :), qout)
    p
end

# Solve Lp = f
# where Lp = Ω * div(pressurgrad(p))
#
# L is rank-1 deficient, so we add the constraint sum(p) = 0, i.e. solve
#
# [0 1] [0]   [0]
# [1 L] [p] = [f]
#
# instead. This way, the matrix is still positive definite.
# For initial guess, we already know the average is zero.
function poisson!(solver::CGPressureSolver, p, f)
    (; setup, abstol, reltol, maxiter, r, L, q, preconditioner) = solver
    (; grid, workgroupsize) = setup
    (; Np, Ip, Ω) = grid
    T = typeof(reltol)

    function innerdot(a, b)
        @kernel function innerdot!(d, a, b, I0)
            I = @index(Global, Cartesian)
            I = I + I0
            d[I-I+I0] += a[I] * b[I]
            # a[I] = b[I]
        end
        # d = zero(eltype(a))
        I0 = first(Ip)
        I0 -= oneunit(I0)
        d = fill!(similar(a, ntuple(Returns(1), length(I0))), 0),
        innerdot!(get_backend(a), workgroupsize)(d, a, b, I0; ndrange = Np)
        d[]
    end

    p .= 0

    # Initial residual
    laplacian!(L, p, setup)

    # Initialize
    q .= 0
    r .= f .- L
    ρ_prev = one(T)
    # residual = norm(r[Ip])
    residual = sqrt(sum(abs2, view(r, Ip)))
    # residual = norm(r)
    tolerance = max(reltol * residual, abstol)
    iteration = 0

    while iteration < maxiter && residual > tolerance
        preconditioner(L, r)

        # ρ = sum(L[Ip] .* r[Ip])
        ρ = dot(view(L, Ip), view(r, Ip))
        # ρ = innerdot(L, r)
        # ρ = dot(L, r)

        β = ρ / ρ_prev
        q .= L .+ β .* q

        # Periodic/symmetric padding (maybe)
        apply_bc_p!(q, T(0), setup)
        laplacian!(L, q, setup)
        # α = ρ / sum(q[Ip] .* L[Ip])
        α = ρ / dot(view(q, Ip), view(L, Ip))
        # α = ρ / innerdot(q, L)
        # α = ρ / dot(q, L)

        p .+= α .* q
        r .-= α .* L

        ρ_prev = ρ
        # residual = norm(r[Ip])
        residual = sqrt(sum(abs2, view(r, Ip)))
        # residual = sqrt(sum(abs2, r))
        # residual = sqrt(innerdot(r, r))

        iteration += 1
    end

    # @show iteration residual tolerance

    p
end

function poisson!(solver::SpectralPressureSolver, p, f)
    (; setup, plan, Ahat, fhat, phat) = solver
    (; Ip) = setup.grid

    f = view(f, Ip)

    fhat .= complex.(f)

    # Fourier transform of right hand side
    mul!(phat, plan, fhat)

    # Solve for coefficients in Fourier space
    @. fhat = -phat / Ahat

    # Transform back
    ldiv!(phat, plan, fhat)
    @. p[Ip] = real(phat)

    p
end
