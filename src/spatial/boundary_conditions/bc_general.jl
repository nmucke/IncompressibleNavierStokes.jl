function bc_general(Nt, Nin, Nb, bc1, bc2, h1, h2)
    # total solution u is written as u = Bb*ub + Bin*uin
    # the boundary conditions can be written as Bbc*u = ybc
    # then u can be written entirely in terms of uin and ybc as:
    # u = (Bin-Btemp*Bbc*Bin)*uin + Btemp*ybc, where
    # Btemp = Bb*(Bbc*Bb)^(-1)
    # Bb, Bin and Bbc depend on type of BC (Neumann/Dirichlet/periodic)
    # val1 and val2 can be scalars or vectors with either the value or the
    # derivative
    # (ghost) points on boundary / grid lines

    # some input checking:
    if Nt != Nin + Nb
        error("Number of inner points plus boundary points is not equal to total points")
    end

    # boundary conditions
    Bbc = spzeros(Nb, Nt)
    ybc1_1D = zeros(Nb)
    ybc2_1D = zeros(Nb)

    if Nb == 0
        # no boundary points, so simply diagonal matrix without boundary contribution
        B1D = sparse(I, Nt, Nt)
        Btemp = spzeros(Nt, 2)
        ybc1 = zeros(2, 1)
        ybc2 = zeros(2, 1)
    elseif Nb == 1
        # one boundary point
        Bb = spzeros(Nt, Nb)
        diagpos = -1
        if bc1 == "dir"
            Bbc[1, 1] = 1
            ybc1_1D[1] = 1        # uLe
            Bb[1, 1] = 1
        elseif bc1 == "pres"
            diagpos = 0
        elseif bc1 == "per"
            diagpos = 0
            Bbc[1, 1] = -1
            Bbc[1, end] = 1
            Bb[end, 1] = 1
        else
            error("not implemented")
        end

        if bc2 == "dir"
            Bbc[Nb, end] = 1
            ybc2_1D[1] = 1        # uRi
            Bb[end, Nb] = 1
        elseif bc2 == "pres"

        elseif bc2 == "per" # actually redundant
            diagpos = 0
            Bbc[1, 1] = -1
            Bbc[1, end] = 1
            Bb[end, 1] = 1
        else
            error("not implemented")
        end

        # boundary matrices
        Bin = spdiagm(Nt, Nin, diagpos => ones(Nin))
    elseif Nb == 2
        # normal situation, 2 boundary points
        # boundary matrices
        Bin = spdiagm(Nt, Nin, -1 => ones(Nin))
        Bb = spzeros(Nt, Nb)
        Bb[1, 1] = 1
        Bb[end, Nb] = 1

        if bc1 == "dir"
            Bbc[1, 1] = 1
            ybc1_1D[1] = 1        # uLe
        elseif bc1 == "pres"
            Bbc[1, 1] = -1
            Bbc[1, 2] = 1
            ybc1_1D[1] = 2 * h1     # duLe
        elseif bc1 == "per"
            Bbc[1, 1] = -1
            Bbc[1, end-1] = 1
            Bbc[Nb, 2] = -1
            Bbc[Nb, end] = 1
        else
            error("not implemented")
        end

        if bc2 == "dir"
            Bbc[Nb, end] = 1
            ybc2_1D[2] = 1        # uRi
        elseif bc2 == "pres"
            Bbc[Nb, end-1] = -1
            Bbc[Nb, end] = 1
            ybc2_1D[2] = 2 * h2     # duRi
        elseif bc2 == "per" # actually redundant
            Bbc[1, 1] = -1
            Bbc[1, end-1] = 1
            Bbc[Nb, 2] = -1
            Bbc[Nb, end] = 1
        else
            error("not implemented")
        end
    else
        error("Nb must be 0, 1, or 2")
    end

    if Nb ∈ [1, 2]
        ybc1 = ybc1_1D
        ybc2 = ybc2_1D

        Btemp = Bb * (Bbc * Bb \ sparse(I, Nb, Nb)) # = inv(Bbc*Bb)
        B1D = Bin - Btemp * Bbc * Bin
    end

    (; B1D, Btemp, ybc1, ybc2)
end
