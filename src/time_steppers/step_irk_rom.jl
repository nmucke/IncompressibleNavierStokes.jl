function step_irk_rom(Vₙ, pₙ, tₙ, Δt, setup)
    ## General implicit Runge-Kutta method for ROM

    # Number of unknowns (modes) in ROM
    M = setup.rom.M

    ## Get coefficients of RK method
    if t ≈ setup.time.t_start
        @unpack A, b, c, = setup.time.method
        # RK_order = check_orderconditions(A, b, c);
        # Number of stages
        nstage = length(b)

        setup.time.A = A
        setup.time.b = b
        setup.time.c = c
        setup.time.nstage = nstage

        # Extend the Butcher tableau
        Is = sparse(I, nstage, nstage)
        Ω_sM = kron(Is, sparse(I, M, M))
        A_ext = kron(A, sparse(I, M, M))
        b_ext = kron(b', sparse(I, M, M))
        c_ext = spdiagm(c)
    end

    ## Preprocessing

    # Store variables at start of time step
    tₙ = t
    Rₙ = R

    # Tⱼ contains the time instances at all stages, tⱼ = [t1;t2;...;ts]
    tⱼ = tₙ + c * Δt

    # Iteration counter
    i = 0
    # Iteration error
    error_nonlinear = zeros(nonlinear_maxit)

    # Vtot contains all stages and is ordered as [u1;v1;u2;v2;...;us;vs];
    # Initialize with the solution at tₙ
    Rtotₙ = kron(ones(nstage), Rₙ)

    # Index in global solution vector
    indxR = 1:M*nstage

    # Starting guess for intermediate stages
    Rⱼ = Rtotₙ

    Qⱼ = Rⱼ

    # Initialize right-hand side for all stages
    _, F_rhs, = F_multiple_ROM(Rⱼ, [], tⱼ, setup, false)
    # Initialize momentum residual
    fmom = -(Rⱼ - Rtotₙ) / Δt + A_ext * F_rhs
    # Initialize residual
    f = fmom

    if setup.solver_settings.nonlinear_Newton == "approximate"
        # Approximate Newton
        # Jacobian based on current solution un
        _, _, Jn = F_ROM(Rₙ, [], tₙ, setup, true)
        # Form iteration matrix, which is now fixed during iterations
        dfmom = Ω_sM / Δt - kron(A, Jn)
        Z = dfmom
    end

    while maximum(abs.(f)) > setup.solver_settings.nonlinear_acc
        if setup.solver_settings.nonlinear_Newton == "approximate"
            # Approximate Newton
            # Do not rebuild Z
            ΔQⱼ = Z \ f
        elseif setup.solver_settings.nonlinear_Newton == "full"
            # Full Newton
            _, _, J = F_multiple_ROM(Rⱼ, [], tⱼ, setup, true)
            # Form iteration matrix
            dfmom = Ω_sM / Δt - A_ext * J

            Z = dfmom

            # Get change
            ΔQⱼ = Z \ f
        end

        # Update solution vector
        Qⱼ = Qⱼ + ΔQⱼ
        Rⱼ = Qⱼ[indxR]

        # Update iteration counter
        i = i + 1

        # Evaluate rhs for next iteration and check residual based on
        # Computed Rⱼ
        _, F_rhs, = F_multiple_ROM(Rⱼ, [], tⱼ, setup, 0)
        fmom = -(Rⱼ - Rtotₙ) / Δt + A_ext * F_rhs

        f = fmom

        error_nonlinear[i] = maximum(abs.(f))
        if i > nonlinear_maxit
            error(["Newton not converged in " num2str(nonlinear_maxit) " iterations"])
        end
    end

    nonlinear_its[n] = i

    # Solution at new time step with b-coefficients of RK method
    R = Rₙ + Δt * (b_ext * F_rhs)

    if setup.rom.pressure_recovery
        q = pressure_additional_solve_ROM(R, tₙ + Δt, setup)
        p = getFOM_pressure(q, t, setup)
    end

    V_new, p_new
end
