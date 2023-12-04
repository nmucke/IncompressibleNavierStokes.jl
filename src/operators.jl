"""
    δ = Offset{D}()

Cartesian index unit vector in `D = 2` or `D = 3` dimensions.
Calling `δ(α)` returns a Cartesian index with `1` in the dimension `α` and zeros
elsewhere.

See <https://b-fg.github.io/2023/05/07/waterlily-on-gpu.html>
for writing kernel loops using Cartesian indices.
"""
struct Offset{D} end

(::Offset{D})(α) where {D} = CartesianIndex(ntuple(β -> β == α ? 1 : 0, D))

"""
    divergence!(div, u, setup)

Compute divergence of velocity field (in-place version).
"""
function divergence!(div, u, setup)
    (; grid, workgroupsize) = setup
    (; Δ, N, Ip) = grid
    D = length(u)
    δ = Offset{D}()
    @kernel function div!(div, u, I0)
        I = @index(Global, Cartesian)
        I = I + I0
        d = zero(eltype(div))
        for α = 1:D
            d += (u[α][I] - u[α][I-δ(α)]) / Δ[α][I[α]]
        end
        div[I] = d
    end
    # All volumes have a right velocity
    # All volumes have a left velocity except the first one
    # Start at second volume
    ndrange = N .- 1
    I0 = 2 * oneunit(first(Ip))
    # ndrange = Np
    # I0 = first(Ip)
    I0 -= oneunit(I0)
    div!(get_backend(div), workgroupsize)(div, u, I0; ndrange)
    div
end

"""
    divergence(u, setup)

Compute divergence of velocity field.
"""
divergence(u, setup) = divergence!(similar(u[1], setup.grid.N), u, setup)

"""
    vorticity(u, setup)

Compute vorticity field.
"""
vorticity(u, setup) = vorticity!(
    length(u) == 2 ? similar(u[1], setup.grid.N) :
    ntuple(α -> similar(u[1], setup.grid.N), length(u)),
    u,
    setup,
)

"""
    vorticity!(ω, u, setup)

Compute vorticity field.
"""
vorticity!(ω, u, setup) = vorticity!(setup.grid.dimension, ω, u, setup)

function vorticity!(::Dimension{2}, ω, u, setup)
    (; grid, workgroupsize) = setup
    (; dimension, Δu, N) = grid
    D = dimension()
    δ = Offset{D}()
    @kernel function ω!(ω, u, I0)
        I = @index(Global, Cartesian)
        I = I + I0
        ω[I] =
            (u[2][I+δ(1)] - u[2][I]) / Δu[1][I[1]] - (u[1][I+δ(2)] - u[1][I]) / Δu[2][I[2]]
    end
    I0 = CartesianIndex(ntuple(Returns(1), D))
    I0 -= oneunit(I0)
    ω!(get_backend(ω), workgroupsize)(ω, u, I0; ndrange = N .- 1)
    ω
end

function vorticity!(::Dimension{3}, ω, u, setup)
    (; grid, workgroupsize) = setup
    (; dimension, Δu, N) = grid
    D = dimension()
    δ = Offset{D}()
    @kernel function ω!(ω, u, I0)
        T = eltype(ω)
        I = @index(Global, Cartesian)
        I = I + I0
        for (α, α₊, α₋) in ((1, 2, 3), (2, 3, 1), (3, 1, 2))
            # α₊ = mod1(α + 1, D)
            # α₋ = mod1(α - 1, D)
            ω[α][I] =
                (u[α₋][I+δ(α₊)] - u[α₋][I]) / Δu[α₊][I[α₊]] -
                (u[α₊][I+δ(α₋)] - u[α₊][I]) / Δu[α₋][I[α₋]]
        end
    end
    I0 = CartesianIndex(ntuple(Returns(1), D))
    I0 -= oneunit(I0)
    ω!(get_backend(ω[1]), workgroupsize)(ω, u, I0; ndrange = N .- 1)
    ω
end

"""
    convection!(F, u, setup)

Compute convective term.
"""
function convection!(F, u, setup)
    (; grid, workgroupsize) = setup
    (; dimension, Δ, Δu, Nu, Iu, A) = grid
    D = dimension()
    δ = Offset{D}()
    @kernel function conv!(F, u, ::Val{α}, ::Val{βrange}, I0) where {α,βrange}
        I = @index(Global, Cartesian)
        I = I + I0
        # for β = 1:D
        KernelAbstractions.Extras.LoopInfo.@unroll for β in βrange
            Δuαβ = α == β ? Δu[β] : Δ[β]
            uαβ1 = A[α][β][2][I[β]-1] * u[α][I-δ(β)] + A[α][β][1][I[β]] * u[α][I]
            uβα1 =
                A[β][α][2][I[α]-(α==β)] * u[β][I-δ(β)] +
                A[β][α][1][I[α]+(α!=β)] * u[β][I-δ(β)+δ(α)]
            uαβ2 = A[α][β][2][I[β]] * u[α][I] + A[α][β][1][I[β]+1] * u[α][I+δ(β)]
            uβα2 = A[β][α][2][I[α]] * u[β][I] + A[β][α][1][I[α]+1] * u[β][I+δ(α)]
            F[α][I] -= (uαβ2 * uβα2 - uαβ1 * uβα1) / Δuαβ[I[β]]
        end
    end
    for α = 1:D
        I0 = first(Iu[α])
        I0 -= oneunit(I0)
        conv!(get_backend(F[1]), workgroupsize)(F, u, Val(α), Val(1:D), I0; ndrange = Nu[α])
    end
    F
end
convection(u, setup) = convection!(zero.(u), u, setup)

"""
    diffusion!(F, u, setup)

Compute diffusive term.
"""
function diffusion!(F, u, setup)
    (; grid, workgroupsize, Re) = setup
    (; dimension, Δ, Δu, Nu, Iu) = grid
    D = dimension()
    δ = Offset{D}()
    ν = 1 / Re
    @kernel function diff!(F, u, ::Val{α}, ::Val{βrange}, I0) where {α,βrange}
        I = @index(Global, Cartesian)
        I = I + I0
        # for β = 1:D
        KernelAbstractions.Extras.LoopInfo.@unroll for β in βrange
            Δuαβ = (α == β ? Δu[β] : Δ[β])
            F[α][I] +=
                ν * (
                    (u[α][I+δ(β)] - u[α][I]) / (β == α ? Δ[β][I[β]+1] : Δu[β][I[β]]) -
                    (u[α][I] - u[α][I-δ(β)]) / (β == α ? Δ[β][I[β]] : Δu[β][I[β]-1])
                ) / Δuαβ[I[β]]
        end
    end
    for α = 1:D
        I0 = first(Iu[α])
        I0 -= oneunit(I0)
        diff!(get_backend(F[1]), workgroupsize)(F, u, Val(α), Val(1:D), I0; ndrange = Nu[α])
    end
    F
end
diffusion(u, setup) = diffusion!(zero.(u), u, setup)

function convectiondiffusion!(F, u, setup)
    (; grid, workgroupsize, Re) = setup
    (; dimension, Δ, Δu, Nu, Iu, A) = grid
    D = dimension()
    δ = Offset{D}()
    ν = 1 / Re
    @kernel function cd!(F, u, ::Val{α}, ::Val{βrange}, I0) where {α,βrange}
        I = @index(Global, Cartesian)
        I = I + I0
        # for β = 1:D
        KernelAbstractions.Extras.LoopInfo.@unroll for β in βrange
            Δuαβ = α == β ? Δu[β] : Δ[β]
            uαβ1 = A[α][β][2][I[β]-1] * u[α][I-δ(β)] + A[α][β][1][I[β]] * u[α][I]
            uβα1 =
                A[β][α][2][I[α]-(α==β)] * u[β][I-δ(β)] +
                A[β][α][1][I[α]+(α!=β)] * u[β][I-δ(β)+δ(α)]
            uαβ2 = A[α][β][2][I[β]] * u[α][I] + A[α][β][1][I[β]+1] * u[α][I+δ(β)]
            uβα2 = A[β][α][2][I[α]] * u[β][I] + A[β][α][1][I[α]+1] * u[β][I+δ(α)]
            uαuβ1 = uαβ1 * uβα1
            uαuβ2 = uαβ2 * uβα2
            ∂βuα1 = (u[α][I] - u[α][I-δ(β)]) / (β == α ? Δ[β][I[β]] : Δu[β][I[β]-1])
            ∂βuα2 = (u[α][I+δ(β)] - u[α][I]) / (β == α ? Δ[β][I[β]+1] : Δu[β][I[β]])
            F[α][I] += (ν * (∂βuα2 - ∂βuα1) - (uαuβ2 - uαuβ1)) / Δuαβ[I[β]]
        end
    end
    for α = 1:D
        I0 = first(Iu[α])
        I0 -= oneunit(I0)
        cd!(get_backend(F[1]), workgroupsize)(F, u, Val(α), Val(1:D), I0; ndrange = Nu[α])
    end
    F
end
convectiondiffusion(u, setup) = convectiondiffusion!(zero.(u), u, setup)

"""
    bodyforce!(F, u, setup)

Compute body force.
"""
function bodyforce!(F, u, t, setup)
    (; grid, workgroupsize, bodyforce) = setup
    (; dimension, Δ, Δu, Nu, Iu, x, xp) = grid
    isnothing(bodyforce) && return F
    D = dimension()
    δ = Offset{D}()
    @kernel function f!(F, force, ::Val{α}, t, I0) where {α}
        I = @index(Global, Cartesian)
        I = I + I0
        F[α][I] +=
            force(Dimension(α), ntuple(β -> α == β ? x[β][1+I[β]] : xp[β][I[β]], D)..., t)
    end
    for α = 1:D
        I0 = first(Iu[α])
        I0 -= oneunit(I0)
        f!(get_backend(F[1]), workgroupsize)(F, bodyforce, Val(α), t, I0; ndrange = Nu[α])
    end
    F
end

"""
    momentum!(F, u, t, setup)

Right hand side of momentum equations, excluding pressure gradient.
Put the result in ``F``.
"""
function momentum!(F, u, t, setup)
    (; grid, closure_model) = setup
    (; dimension) = grid
    D = dimension()
    for α = 1:D
        F[α] .= 0
    end
    # diffusion!(F, u, setup)
    # convection!(F, u, setup)
    convectiondiffusion!(F, u, setup)
    bodyforce!(F, u, t, setup)
    if !isnothing(closure_model)
        m = closure_model(u)
        for α = 1:D
            F[α] .+= m[α]
        end
    end
    F
end

"""
    momentum(u, t, setup)

Right hand side of momentum equations, excluding pressure gradient.
"""
momentum(u, t, setup) = momentum!(zero.(u), u, t, setup)

"""
    pressuregradient!(G, p, setup)

Compute pressure gradient (in-place).
"""
function pressuregradient!(G, p, setup)
    (; grid, workgroupsize) = setup
    (; dimension, Δu, Nu, Iu) = grid
    D = dimension()
    δ = Offset{D}()
    @kernel function G!(G, p, ::Val{α}, I0) where {α}
        I = @index(Global, Cartesian)
        I = I0 + I
        G[α][I] = (p[I+δ(α)] - p[I]) / Δu[α][I[α]]
    end
    D = dimension()
    for α = 1:D
        I0 = first(Iu[α])
        I0 -= oneunit(I0)
        G!(get_backend(G[1]), workgroupsize)(G, p, Val(α), I0; ndrange = Nu[α])
    end
    G
end

"""
    pressuregradient(p, setup)

Compute pressure gradient.
"""
pressuregradient(p, setup) = pressuregradient!(
    ntuple(α -> similar(p, setup.grid.N), setup.grid.dimension()),
    p,
    setup,
)

"""
    laplacian!(L, p, setup)

Compute Laplacian of pressure field (in-place version).
"""
function laplacian!(L, p, setup)
    (; grid, workgroupsize) = setup
    (; dimension, Δ, Δu, N, Np, Ip, Ω) = grid
    D = dimension()
    δ = Offset{D}()
    @kernel function lap!(L, p, I0)
        I = @index(Global, Cartesian)
        I = I + I0
        lap = zero(eltype(p))
        for α = 1:D
            lap +=
                Ω[I] / Δ[α][I[α]] *
                ((p[I+δ(α)] - p[I]) / Δu[α][I[α]] - (p[I] - p[I-δ(α)]) / Δu[α][I[α]-1])
        end
        L[I] = lap
    end
    # All volumes have a right velocity
    # All volumes have a left velocity except the first one
    # Start at second volume
    ndrange = Np
    I0 = first(Ip)
    I0 -= oneunit(I0)
    lap!(get_backend(L), workgroupsize)(L, p, I0; ndrange)
    L
end

"""
    laplacian(p, setup)

Compute Laplacian of pressure field.
"""
laplacian(p, setup) = laplacian!(similar(p), p, setup)

function laplacian_mat(setup)
    (; grid, boundary_conditions) = setup
    (; dimension, x, N, Np, Ip, Δ, Δu, Ω) = grid
    backend = get_backend(x[1])
    T = eltype(x[1])
    D = dimension()
    δ = Offset{D}()
    Ia = first(Ip)
    Ib = last(Ip)
    I = KernelAbstractions.zeros(backend, CartesianIndex{D}, 0)
    J = KernelAbstractions.zeros(backend, CartesianIndex{D}, 0)
    val = KernelAbstractions.zeros(backend, T, 0)
    I0 = Ia - oneunit(Ia)
    for α = 1:D
        a, b = boundary_conditions[α]
        i = Ip[ntuple(β -> α == β ? (2:Np[α]-1) : (:), D)...][:]
        ia = Ip[ntuple(β -> α == β ? (1:1) : (:), D)...][:]
        ib = Ip[ntuple(β -> α == β ? (Np[α]:Np[α]) : (:), D)...][:]
        for (aa, bb, j) in [(a, nothing, ia), (nothing, nothing, i), (nothing, b, ib)]
            vala = @.(Ω[j] / Δ[α][getindex.(j, α)] / Δu[α][getindex.(j, α)-1])
            if isnothing(aa)
                J = [J; j .- [δ(α)]; j]
                I = [I; j; j]
                val = [val; vala; -vala]
            elseif aa isa PressureBC
                J = [J; j]
                I = [I; j]
                val = [val; -vala]
            elseif aa isa PeriodicBC
                J = [J; ib; j]
                I = [I; j; j]
                val = [val; vala; -vala]
            elseif aa isa SymmetricBC
                J = [J; ia; j]
                I = [I; j; j]
                val = [val; vala; -vala]
            elseif aa isa DirichletBC
            end

            valb = @.(Ω[j] / Δ[α][getindex.(j, α)] / Δu[α][getindex.(j, α)])
            if isnothing(bb)
                J = [J; j; j .+ [δ(α)]]
                I = [I; j; j]
                val = [val; -valb; valb]
            elseif bb isa PressureBC
                # The weight of the "right" BC is zero, but still needs a J inside Ip, so
                # just set it to ib
                J = [J; j]
                I = [I; j]
                val = [val; -valb]
            elseif bb isa PeriodicBC
                J = [J; j; ia]
                I = [I; j; j]
                val = [val; -valb; valb]
            elseif bb isa SymmetricBC
                J = [J; j; ib]
                I = [I; j; j]
                val = [val; -valb; valb]
            elseif bb isa DirichletBC
            end
            # val = vcat(
            #     val,
            #     map(I -> Ω[I] / Δ[α][I[α]] / Δu[α][I[α]-1], j),
            #     map(I -> -Ω[I] / Δ[α][I[α]] * (1 / Δu[α][I[α]] + 1 / Δu[α][I[α]-1]), j),
            #     map(I -> Ω[I] / Δ[α][I[α]] / Δu[α][I[α]], j),
        end
    end
    # Go back to CPU, otherwise get following error:
    # ERROR: CUDA error: an illegal memory access was encountered (code 700, ERROR_ILLEGAL_ADDRESS)
    I = Array(I)
    J = Array(J)
    # I = I .- I0
    # J = J .- I0
    I = I .- [I0]
    J = J .- [I0]
    # linear = copyto!(KernelAbstractions.zeros(backend, Int, Np), collect(LinearIndices(Ip)))
    linear = LinearIndices(Ip)
    I = linear[I]
    J = linear[J]

    # Assemble on CPU, since CUDA overwrites instead of adding
    L = sparse(I, J, Array(val))
    # II = copyto!(KernelAbstractions.zeros(backend, Int, length(I)), I)
    # JJ = copyto!(KernelAbstractions.zeros(backend, Int, length(J)), J)
    # sparse(II, JJ, val)

    L
    # Ω isa CuArray ? cu(L) : L
end

# @inline function ∂x(uα, I, ::Val{α}, ::Val{β}, Δβ, Δuβ) where {α,β}
#     D = length(I)
#     δ = Offset{D}()
#     α == β ? (uα[I] - uα[I-δ(β)]) / Δβ[I[β]] :
#     (
#         (uα[I+δ(β)] - uα[I]) / Δuβ[I[β]] +
#         (uα[I-δ(α)+δ(β)] - uα[I-δ(α)]) / Δuβ[I[β]] +
#         (uα[I] - uα[I-δ(β)]) / Δuβ[I[β]-1] +
#         (uα[I-δ(α)] - uα[I-δ(α)-δ(β)]) / Δuβ[I[β]-1]
#     ) / 4
# end
# @inline ∇(::Val{2}, u, I, Δ, Δu) = SMatrix{2,2,eltype(u[1]),4}(
#     ∂x(u[1], I, Val(1), Val(1), Δ[1], Δu[1]),
#     ∂x(u[2], I, Val(2), Val(1), Δ[1], Δu[1]),
#     ∂x(u[1], I, Val(1), Val(2), Δ[2], Δu[2]),
#     ∂x(u[2], I, Val(2), Val(2), Δ[2], Δu[2]),
# )
# @inline ∇(::Val{3}, u, I, Δ, Δu) = SMatrix{3,3,eltype(u[1]),9}(
#     ∂x(u[1], I, Val(1), Val(1), Δ[1], Δu[1]),
#     ∂x(u[2], I, Val(2), Val(1), Δ[1], Δu[1]),
#     ∂x(u[3], I, Val(3), Val(1), Δ[1], Δu[1]),
#     ∂x(u[1], I, Val(1), Val(2), Δ[2], Δu[2]),
#     ∂x(u[2], I, Val(2), Val(2), Δ[2], Δu[2]),
#     ∂x(u[3], I, Val(3), Val(2), Δ[2], Δu[2]),
#     ∂x(u[1], I, Val(1), Val(3), Δ[3], Δu[3]),
#     ∂x(u[2], I, Val(2), Val(3), Δ[3], Δu[3]),
#     ∂x(u[3], I, Val(3), Val(3), Δ[3], Δu[3]),
# )
#
# @inline function strain(valD, u, I, Δ, Δu)
#     ∇u = ∇(valD, u, I, Δ, Δu)
#     (∇u + ∇u') / 2
# end
#
# @inline gridsize(::Val{2}, Δ, I) = sqrt(Δ[1][I[1]]^2 + Δ[2][I[2]]^2)
# @inline gridsize(::Val{3}, Δ, I) = sqrt(Δ[1][I[1]]^2 + Δ[2][I[2]]^2 + Δ[3][I[3]]^2)

function smagtensor!(σ, u, θ, setup)
    # TODO: Combine with normal diffusion tensor
    (; boundary_conditions, grid, workgroupsize) = setup
    (; dimension, Np, Ip, Δ, Δu) = grid
    D = dimension()
    δ = Offset{D}()
    @assert D == 2
    @kernel function σ!(σ, u, I0)
        ∂x(uα, I, ::Val{α}, ::Val{β}, Δβ, Δuβ) where {α,β} =
            α == β ? (uα[I] - uα[I-δ(β)]) / Δβ[I[β]] :
            (
                (uα[I+δ(β)] - uα[I]) / Δuβ[I[β]] +
                (uα[I-δ(α)+δ(β)] - uα[I-δ(α)]) / Δuβ[I[β]] +
                (uα[I] - uα[I-δ(β)]) / Δuβ[I[β]-1] +
                (uα[I-δ(α)] - uα[I-δ(α)-δ(β)]) / Δuβ[I[β]-1]
            ) / 4
        I = @index(Global, Cartesian)
        I = I + I0
        if D == 2
            ∇u = SMatrix{2,2,eltype(u[1]),4}(
                ∂x(u[1], I, Val(1), Val(1), Δ[1], Δu[1]),
                ∂x(u[2], I, Val(2), Val(1), Δ[1], Δu[1]),
                ∂x(u[1], I, Val(1), Val(2), Δ[2], Δu[2]),
                ∂x(u[2], I, Val(2), Val(2), Δ[2], Δu[2]),
            )
            d = sqrt(Δ[1][I[1]]^2 + Δ[2][I[2]]^2)
        elseif D == 3
            # TODO: Figure out why KA doesn't like I[3] when D == 2
            # ∇u = SMatrix{3,3,eltype(u[1]),9}(
            #     ∂x(u[1], I, Val(1), Val(1), Δ[1], Δu[1]),
            #     ∂x(u[2], I, Val(2), Val(1), Δ[1], Δu[1]),
            #     ∂x(u[3], I, Val(3), Val(1), Δ[1], Δu[1]),
            #     ∂x(u[1], I, Val(1), Val(2), Δ[2], Δu[2]),
            #     ∂x(u[2], I, Val(2), Val(2), Δ[2], Δu[2]),
            #     ∂x(u[3], I, Val(3), Val(2), Δ[2], Δu[2]),
            #     ∂x(u[1], I, Val(1), Val(3), Δ[3], Δu[3]),
            #     ∂x(u[2], I, Val(2), Val(3), Δ[3], Δu[3]),
            #     ∂x(u[3], I, Val(3), Val(3), Δ[3], Δu[3]),
            # )
            # d = sqrt(Δ[1][I[1]]^2 + Δ[2][I[2]]^2 + Δ[3][I[3]]^2)
        end
        # S = strain(Val(D), u, I, Δ, Δu)
        # d = gridsize(Val(D), Δ, I)
        S = (∇u + ∇u') / 2
        # νt = θ^2 * d^2 * sqrt(2 * dot(S, S))
        νt = θ^2 * d^2 * sqrt(2 * sum(S .* S))
        σ[I] = 2 * νt * S
    end
    I0 = first(Ip)
    I0 -= oneunit(I0)
    σ!(get_backend(u[1]), workgroupsize)(σ, u, I0; ndrange = Np)
    σ
end

function smagorinsky!(s, σ, setup)
    (; boundary_conditions, grid, workgroupsize) = setup
    (; dimension, Nu, Iu, Δ, Δu, A) = grid
    D = dimension()
    δ = Offset{D}()
    @kernel function s!(s, σ, ::Val{α}, ::Val{βrange}, I0) where {α,βrange}
        I = @index(Global, Cartesian)
        I = I + I0
        s[α][I] = 0
        # for β = 1:D
        KernelAbstractions.Extras.LoopInfo.@unroll for β in βrange
            Δuαβ = α == β ? Δu[β] : Δ[β]
            if α == β
                σαβ2 = σ[I+δ(β)][α, β]
                σαβ1 = σ[I][α, β]
            else
                # TODO: Add interpolation weights for non-uniform case
                σαβ2 =
                    (
                        σ[I][α, β] +
                        σ[I+δ(β)][α, β] +
                        σ[I+δ(α)+δ(β)][α, β] +
                        σ[I+δ(α)][α, β]
                    ) / 4
                σαβ1 =
                    (
                        σ[I-δ(β)][α, β] +
                        σ[I][α, β] +
                        σ[I+δ(α)-δ(β)][α, β] +
                        σ[I+δ(α)][α, β]
                    ) / 4
            end
            s[α][I] += (σαβ2 - σαβ1) / Δuαβ[I[β]]
        end
    end
    for α = 1:D
        I0 = first(Iu[α])
        I0 -= oneunit(I0)
        s!(get_backend(s[1]), workgroupsize)(s, σ, Val(α), Val(1:D), I0; ndrange = Nu[α])
    end
    s
end

function smagorinsky_closure(setup)
    (; dimension, x, N) = setup.grid
    D = dimension()
    backend = get_backend(x[1])
    T = eltype(x[1])
    σ = KernelAbstractions.zeros(backend, SMatrix{D,D,T,D * D}, N)
    s = ntuple(α -> KernelAbstractions.zeros(backend, T, N), D)
    function closure(u, θ)
        smagtensor!(σ, u, θ, setup)
        smagorinsky!(s, σ, setup)
    end
end

"""
    interpolate_u_p(u, setup)

Interpolate velocity to pressure points.
"""
interpolate_u_p(u, setup) =
    interpolate_u_p!(ntuple(α -> similar(u[1], setup.grid.N), length(u)), u, setup)

"""
    interpolate_u_p!(up, u, setup)

Interpolate velocity to pressure points.
"""
function interpolate_u_p!(up, u, setup)
    (; boundary_conditions, grid, workgroupsize, Re, bodyforce) = setup
    (; dimension, Np, Ip) = grid
    D = dimension()
    δ = Offset{D}()
    @kernel function int!(up, u, ::Val{α}, I0) where {α}
        I = @index(Global, Cartesian)
        I = I + I0
        up[α][I] = (u[α][I-δ(α)] + u[α][I]) / 2
    end
    for α = 1:D
        I0 = first(Ip)
        I0 -= oneunit(I0)
        int!(get_backend(up[1]), workgroupsize)(up, u, Val(α), I0; ndrange = Np)
    end
    up
end

"""
    interpolate_ω_p(ω, setup)

Interpolate vorticity to pressure points.
"""
interpolate_ω_p(ω, setup) = interpolate_ω_p!(
    setup.grid.dimension() == 2 ? similar(ω, setup.grid.N) :
    ntuple(α -> similar(ω[1], setup.grid.N), length(ω)),
    ω,
    setup,
)

"""
    interpolate_ω_p!(ωp, ω, setup)

Interpolate vorticity to pressure points.
"""
interpolate_ω_p!(ωp, ω, setup) = interpolate_ω_p!(setup.grid.dimension, ωp, ω, setup)

function interpolate_ω_p!(::Dimension{2}, ωp, ω, setup)
    (; boundary_conditions, grid, workgroupsize, Re, bodyforce) = setup
    (; dimension, Np, Ip) = grid
    D = dimension()
    δ = Offset{D}()
    @kernel function int!(ωp, ω, I0)
        I = @index(Global, Cartesian)
        I = I + I0
        ωp[I] = (ω[I-δ(1)-δ(2)] + ω[I]) / 2
    end
    I0 = first(Ip)
    I0 -= oneunit(I0)
    int!(get_backend(ωp), workgroupsize)(ωp, ω, I0; ndrange = Np)
    ωp
end

function interpolate_ω_p!(::Dimension{3}, ωp, ω, setup)
    (; boundary_conditions, grid, workgroupsize, Re) = setup
    (; dimension, Np, Ip) = grid
    D = dimension()
    δ = Offset{D}()
    @kernel function int!(ωp, ω, ::Val{α}, I0) where {α}
        I = @index(Global, Cartesian)
        I = I + I0
        α₊ = mod1(α + 1, D)
        α₋ = mod1(α - 1, D)
        ωp[α][I] = (ω[α][I-δ(α₊)-δ(α₋)] + ω[α][I]) / 2
    end
    I0 = first(Ip)
    I0 -= oneunit(I0)
    for α = 1:D
        int!(get_backend(ωp[1]), workgroupsize)(ωp, ω, Val(α), I0; ndrange = Np)
    end
    ωp
end

"""
    Dfield!(d, G, p, setup; ϵ = eps(eltype(p)))

Compute the ``D``-field [LiJiajia2019](@cite) given by

```math
D = \\frac{2 | \\nabla p |}{\\nabla^2 p}.
```
"""
function Dfield!(d, G, p, setup; ϵ = eps(eltype(p)))
    (; boundary_conditions, grid, workgroupsize) = setup
    (; dimension, Np, Ip, Δ) = grid
    T = eltype(p)
    D = dimension()
    δ = Offset{D}()
    @kernel function D!(d, G, p, I0)
        I = @index(Global, Cartesian)
        I = I + I0
        g = zero(eltype(p))
        for α = 1:D
            g += (G[α][I-δ(α)] + G[α][I])^2
        end
        lap = zero(eltype(p))
        # for α = 1:D
        #     lap += (G[α][I] - G[α][I-δ(α)]) / Δ[α][I[α]]
        # end
        if D == 2
            lap += (G[1][I] - G[1][I-δ(1)]) / Δ[1][I[1]]
            lap += (G[2][I] - G[2][I-δ(2)]) / Δ[2][I[2]]
        elseif D == 3
            lap += (G[1][I] - G[1][I-δ(1)]) / Δ[1][I[1]]
            lap += (G[2][I] - G[2][I-δ(2)]) / Δ[2][I[2]]
            lap += (G[3][I] - G[3][I-δ(3)]) / Δ[3][I[3]]
        end
        lap = lap > 0 ? max(lap, ϵ) : min(lap, -ϵ)
        # lap = abs(lap)
        d[I] = sqrt(g) / 2 / lap
    end
    pressuregradient!(G, p, setup)
    I0 = first(Ip)
    I0 -= oneunit(I0)
    D!(get_backend(p), workgroupsize)(d, G, p, I0; ndrange = Np)
    d
end

"""
    Dfield(p, setup)

Compute the ``D``-field.
"""
Dfield(p, setup) = Dfield!(
    zero(p),
    ntuple(α -> similar(p, setup.grid.N), setup.grid.dimension()),
    p,
    setup,
)

"""
    Qfield!(Q, u, setup; ϵ = eps(eltype(Q)))

Compute ``Q``-field [Jeong1995](@cite) given by

```math
Q = - \\frac{1}{2} \\sum_{α, β} \\frac{\\partial u^α}{\\partial x^β}
\\frac{\\partial u^β}{\\partial x^α}.
```
"""
function Qfield!(Q, u, setup; ϵ = eps(eltype(Q)))
    (; boundary_conditions, grid, workgroupsize) = setup
    (; dimension, Np, Ip, Δ) = grid
    D = dimension()
    δ = Offset{D}()
    @kernel function Q!(Q, u, I0)
        I = @index(Global, Cartesian)
        I = I + I0
        q = zero(eltype(Q))
        for α = 1:D, β = 1:D
            q -=
                (u[α][I] - u[α][I-δ(β)]) / Δ[β][I[β]] * (u[β][I] - u[β][I-δ(α)]) /
                Δ[α][I[α]] / 2
        end
        Q[I] = q
    end
    I0 = first(Ip)
    I0 -= oneunit(I0)
    Q!(get_backend(u[1]), workgroupsize)(Q, u, I0; ndrange = Np)
    Q
end

"""
    Qfield(u, setup)

Compute the ``Q``-field.
"""
Qfield(u, setup) = Qfield!(similar(u[1], setup.grid.N), u, setup)

"""
    eig2field!(λ, u, setup)

Compute the second eigenvalue of ``S^2 + \\Omega^2``.
"""
function eig2field!(λ, u, setup)
    (; boundary_conditions, grid, workgroupsize) = setup
    (; dimension, Np, Ip, Δ, Δu) = grid
    D = dimension()
    δ = Offset{D}()
    @assert D == 3 "eig2 only implemented in 3D"
    @kernel function λ!(λ, u, I0)
        I = @index(Global, Cartesian)
        I = I + I0
        ∂x(uα, I, ::Val{α}, ::Val{β}, Δβ, Δuβ) where {α,β} =
            α == β ? (uα[I] - uα[I-δ(β)]) / Δβ[I[β]] :
            (
                (uα[I+δ(β)] - uα[I]) / Δuβ[I[β]] +
                (uα[I-δ(α)+δ(β)] - uα[I-δ(α)]) / Δuβ[I[β]] +
                (uα[I] - uα[I-δ(β)]) / Δuβ[I[β]-1] +
                (uα[I-δ(α)] - uα[I-δ(α)-δ(β)]) / Δuβ[I[β]-1]
            ) / 4
        ∇u = SMatrix{3,3,eltype(λ),9}(
            ∂x(u[1], I, Val(1), Val(1), Δ[1], Δu[1]),
            ∂x(u[2], I, Val(2), Val(1), Δ[1], Δu[1]),
            ∂x(u[3], I, Val(3), Val(1), Δ[1], Δu[1]),
            ∂x(u[1], I, Val(1), Val(2), Δ[2], Δu[2]),
            ∂x(u[2], I, Val(2), Val(2), Δ[2], Δu[2]),
            ∂x(u[3], I, Val(3), Val(2), Δ[2], Δu[2]),
            ∂x(u[1], I, Val(1), Val(3), Δ[3], Δu[3]),
            ∂x(u[2], I, Val(2), Val(3), Δ[3], Δu[3]),
            ∂x(u[3], I, Val(3), Val(3), Δ[3], Δu[3]),
        )
        S = @. (∇u + ∇u') / 2
        Ω = @. (∇u - ∇u') / 2
        λ[I] = eigvals(S^2 + Ω^2)[2]
    end
    I0 = first(Ip)
    I0 -= oneunit(I0)
    λ!(get_backend(u[1]), workgroupsize)(λ, u, I0; ndrange = Np)
    λ
end

"""
    eig2field(u, setup)

Compute the second eigenvalue of ``S^2 + \\Omega^2``.
"""
eig2field(u, setup) = eig2field!(similar(u[1], setup.grid.N), u, setup)

"""
    kinetic_energy(setup, u)

Compute total kinetic energy. The velocity components are interpolated to the
volume centers and squared.
"""
function kinetic_energy(u, setup)
    (; dimension, Ω, Ip) = setup.grid
    D = dimension()
    up = interpolate_u_p(u, setup)
    E = zero(eltype(up[1]))
    for α = 1:D
        # E += sum(I -> Ω[I] * up[α][I]^2, Ip)
        E += sum(Ω[Ip] .* up[α][Ip] .^ 2)
    end
    E
end
