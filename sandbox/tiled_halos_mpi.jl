import MPI

using Oceananigans

@inline index2rank(I, J, Mx, My) = J*My + I
@inline rank2index(r, Mx, My) = div(r, Mx), mod(r, My)

function fill_halo_regions_mpi!(FT, arch, Nx, Ny, Nz, Mx, My)
    Lx, Ly, Lz = 10, 10, 10

    Nx′, Ny′, Nz′ = Int(Nx/Mx), Int(Ny/My), Nz
    Lx′, Ly′, Lz′ = Lx/Mx, Ly/My, Lz
    
    comm = MPI.COMM_WORLD

    MPI.Barrier(comm)

    rank = MPI.Comm_rank(comm)
    size = MPI.Comm_size(comm)

    I, J = rank2index(rank, Mx, My)
    I⁻, I⁺ = mod(I-1, Mx), mod(I+1, Mx)
    J⁻, J⁺ = mod(J-1, My), mod(J+1, My)
    Nx′, Ny′, Nz′ = Int(Nx/Mx), Int(Ny/My), Nz
    Lx′, Ly′, Lz′ = Lx/Mx, Ly/My, Lz

    north_rank = index2rank(I,  J⁻, Mx, My)
    south_rank = index2rank(I,  J⁺, Mx, My)
    east_rank  = index2rank(I⁺, J,  Mx, My)
    west_rank  = index2rank(I⁻, J,  Mx, My)

    send_reqs = MPI.Request[]
    if rank == 0
        rands = rand(Nx, Ny, Nz)

        for r in 0:Mx*My-1
            I′, J′ = rank2index(r, Mx, My)
            i1, i2 = I′*Nx′+1, (I′+1)*Nx′
            j1, j2 = J′*Ny′+1, (J′+1)*Ny′
            send_mesg = rands[i1:i2, j1:j2, :]

            tag = 100 + r
            println("[rank $rank] Sending R[$i1:$i2, $j1:$j2, :] to rank $r with tag $tag...")

            sreq = MPI.Isend(send_mesg, r, tag, comm)
            push!(send_reqs, sreq)
        end

        MPI.Waitall!(send_reqs)
    end

    tile_grid = RegularCartesianGrid((Nx′, Ny′, Nz′), (Lx′, Ly′, Lz′))
    tile = CellField(FT, arch, tile_grid)

    recv_mesg = zeros(FT, Nx′, Ny′, Nz′)

    tag = 100 + rank
    println("[rank $rank] Receiving message from rank 0 with tag $tag...")
    rreq = MPI.Irecv!(recv_mesg, 0, tag, comm)

    data(tile) .= recv_mesg

    stats = MPI.Waitall!([rreq])

    MPI.Barrier(comm)
end

MPI.Init()
fill_halo_regions_mpi!(Float64, CPU(), 16, 16, 16, 2, 2)
MPI.Finalize()
