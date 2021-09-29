"""
    convection(V, C, t, setup, getJacobian)

evaluate convective terms and, optionally, Jacobians
V: velocity field
C: "convection" field: e.g. d(c_x u)/dx + d(c_y u)/dy; usually c_x = u,
c_y = v
"""
function convection(V, C, t, setup, getJacobian)
    @unpack order4 = setup.discretization
    @unpack regularization = setup.case
    @unpack α = setup.discretization
    @unpack Nu, Nv, NV, indu, indv = setup.grid

    Jacu = spzeros(Nu, NV)
    Jacv = spzeros(Nv, NV)

    uₕ = V[indu]
    vₕ = V[indv]

    cu = C[indu]
    cv = C[indv]

    if regularization == "no"
        # no regularization
        convu, convv, Jacu, Jacv = convection_components(C, V, setup, getJacobian, false)

        if order4
            convu3, convv3, Jacu3, Jacv3 =
                convection_components(C, V, setup, getJacobian, true)
            @. convu = α * convu - convu3
            @. convv = α * convv - convv3
            @. Jacu = α * Jacu - Jacu3
            @. Jacv = α * Jacv - Jacv3
        end
    elseif regularization == "leray"
        # Leray
        # TODO: needs finishing

        # filter the convecting field
        cu_f = filter_convection(cu, Diffu_f, yDiffu_f, α) #uₕ + (α^2)*Re*(Diffu*uₕ + yDiffu);
        cv_f = filter_convection(cv, Diffv_f, yDiffv_f, α)

        C_filtered = [cu_f; cv_f]

        # divergence of filtered velocity field; should be zero!
        maxdiv_f = maximum(abs.(M * C_filtered + yM))

        convu, convv, Jacu, Jacv = convection_components(C_filtered, V, setup, getJacobian)
    elseif regularization == "C2"
        ## C2

        cu_f = filter_convection(cu, Diffu_f, yDiffu_f, α) #uₕ + (α^2)*Re*(Diffu*uₕ + yDiffu);
        cv_f = filter_convection(cv, Diffv_f, yDiffv_f, α)

        uₕ_f = filter_convection(uₕ, Diffu_f, yDiffu_f, α) #uₕ + (α^2)*Re*(Diffu*uₕ + yDiffu);
        vₕ_f = filter_convection(vₕ, Diffv_f, yDiffv_f, α)

        C_filtered = [cu_f; cv_f]
        V_filtered = [uₕ_f; vₕ_f]

        # divergence of filtered velocity field; should be zero!
        maxdiv_f = maximum(abs.(M * C_filtered + yM))

        convu, convv, Jacu, Jacv =
            convection_components(C_filtered, V_filtered, setup, getJacobian)

        convu = filter_convection(convu, Diffu_f, yDiffu_f, α)
        convv = filter_convection(convv, Diffv_f, yDiffv_f, α)
    elseif regularization == "C4"
        # C4 consists of 3 terms:
        # C4 = conv(filter(u), filter(u)) + filter(conv(filter(u), u') +
        #      filter(conv(u', filter(u)))
        # where u' = u - filter(u)

        # filter both convecting and convected velocity
        uₕ_f = filter_convection(uₕ, Diffu_f, yDiffu_f, α) #uₕ + (α^2)*Re*(Diffu*uₕ + yDiffu);
        vₕ_f = filter_convection(vₕ, Diffv_f, yDiffv_f, α)

        V_filtered = [uₕ_f; vₕ_f]

        dV = V - V_filtered

        cu_f = filter_convection(cu, Diffu_f, yDiffu_f, α) #uₕ + (α^2)*Re*(Diffu*uₕ + yDiffu);
        cv_f = filter_convection(cv, Diffv_f, yDiffv_f, α)

        C_filtered = [cu_f; cv_f]
        dC = C - C_filtered

        # divergence of filtered velocity field; should be zero!
        maxdiv_f[n] = maximum(abs.(M * V_filtered + yM))

        convu1, convv1, Jacu, Jacv =
            convection_components(C_filtered, V_filtered, setup, getJacobian)

        convu2, convv2, Jacu, Jacv =
            convection_components(C_filtered, dV, setup, getJacobian)

        convu3, convv3, Jacu, Jacv =
            convection_components(dC, V_filtered, setup, getJacobian)

        convu = convu1 + filter_convection(convu2 + convu3, Diffu_f, yDiffu_f, α)
        convv = convv1 + filter_convection(convv2 + convv3, Diffv_f, yDiffv_f, α)
    end
    convu, convv, Jacu, Jacv
end

function convection_components(C, V, setup, getJacobian, order4 = false)
    if order4
        Cux = setup.discretization.Cux3
        Cuy = setup.discretization.Cuy3
        Cvx = setup.discretization.Cvx3
        Cvy = setup.discretization.Cvy3

        Au_ux = setup.discretization.Au_ux3
        Au_uy = setup.discretization.Au_uy3
        Av_vx = setup.discretization.Av_vx3
        Av_vy = setup.discretization.Av_vy3

        yAu_ux = setup.discretization.yAu_ux3
        yAu_uy = setup.discretization.yAu_uy3
        yAv_vx = setup.discretization.yAv_vx3
        yAv_vy = setup.discretization.yAv_vy3

        Iu_ux = setup.discretization.Iu_ux3
        Iv_uy = setup.discretization.Iv_uy3
        Iu_vx = setup.discretization.Iu_vx3
        Iv_vy = setup.discretization.Iv_vy3

        yIu_ux = setup.discretization.yIu_ux3
        yIv_uy = setup.discretization.yIv_uy3
        yIu_vx = setup.discretization.yIu_vx3
        yIv_vy = setup.discretization.yIv_vy3
    else
        @unpack Cux, Cuy, Cvx, Cvy = setup.discretization
        @unpack Au_ux, Au_uy, Av_vx, Av_vy = setup.discretization
        @unpack yAu_ux, yAu_uy, yAv_vx, yAv_vy = setup.discretization
        @unpack Iu_ux, Iv_uy, Iu_vx, Iv_vy = setup.discretization
        @unpack yIu_ux, yIv_uy, yIu_vx, yIv_vy = setup.discretization
    end

    @unpack Nu, Nv, NV, indu, indv = setup.grid

    Jacu = spzeros(Nu, NV)
    Jacv = spzeros(Nv, NV)

    uₕ = V[indu]
    vₕ = V[indv]

    cu = C[indu]
    cv = C[indv]

    u_ux = Au_ux * uₕ + yAu_ux                 # u at ux
    uf_ux = Iu_ux * cu + yIu_ux                 # ubar at ux
    du2dx = Cux * (uf_ux .* u_ux)

    u_uy = Au_uy * uₕ + yAu_uy                 # u at uy
    vf_uy = Iv_uy * cv + yIv_uy                 # vbar at uy
    duvdy = Cuy * (vf_uy .* u_uy)

    v_vx = Av_vx * vₕ + yAv_vx                 # v at vx
    uf_vx = Iu_vx * cu + yIu_vx                 # ubar at vx
    duvdx = Cvx * (uf_vx .* v_vx)

    v_vy = Av_vy * vₕ + yAv_vy                 # v at vy
    vf_vy = Iv_vy * cv + yIv_vy                 # vbar at vy
    dv2dy = Cvy * (vf_vy .* v_vy)

    convu = du2dx + duvdy
    convv = duvdx + dv2dy

    if getJacobian
        Newton_factor = setup.solver_settings.Newton_factor
        N1 = length(u_ux) #setup.grid.N1;
        N2 = length(u_uy) #setup.grid.N2;
        N3 = length(v_vx) #setup.grid.N3;
        N4 = length(v_vy) #setup.grid.N4;

        ## convective terms, u-component
        # c^n * u^(n+1), c = u
        C1 = Cux * spdiagm(uf_ux)
        C2 = Cux * spdiagm(u_ux) * Newton_factor
        Conv_ux_11 = C1 * Au_ux + C2 * Iu_ux

        C1 = Cuy * spdiagm(vf_uy)
        C2 = Cuy * spdiagm(u_uy) * Newton_factor
        Conv_uy_11 = C1 * Au_uy
        Conv_uy_12 = C2 * Iv_uy

        Jacu = [Conv_ux_11 + Conv_uy_11 Conv_uy_12]

        ## convective terms, v-component
        C1 = Cvx * spdiagm(uf_vx)
        C2 = Cvx * spdiagm(v_vx) * Newton_factor
        Conv_vx_21 = C2 * Iu_vx
        Conv_vx_22 = C1 * Av_vx

        C1 = Cvy * spdiagm(vf_vy)
        C2 = Cvy * spdiagm(v_vy) * Newton_factor
        Conv_vy_22 = C1 * Av_vy + C2 * Iv_vy

        Jacv = [Conv_vx_21 (Conv_vx_22 + Conv_vy_22)]
    end

    convu, convv, Jacu, Jacv
end