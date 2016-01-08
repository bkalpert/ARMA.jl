#
# Operations on matrices using *random* data.
# Algorithms from "Finding structure with randomness: Probabilistic
# algorithms for constructing approximate matrix decompositions"
# by Nathan Halko, Per-Gunnar Martinsson, Joel A. Tropp.
# See http://arxiv.org/abs/0909.4061.


"Find range of matrix `A` (with size m,n) using `num_lhs` random vectors and
with `q` power iterations. Returns range matrix Q of size (m,num_lhs).

Based on Halko Martinsson & Tropp Algorithm 4.3."

function find_range_randomly(A::Matrix, num_lhs::Integer, q=1)
    m,n = size(A)
    Omega = randn(n, num_lhs)
    Y = A*Omega
    for _ in 1:q
        Y = A' * Y
        Y = A * Y
    end
    Q,R = qr(Y)
    Q
end


"Compute a randomized SVD, from Halko Martinsson & Tropp Algorithm 5.1."

function find_svd_randomly(A::Matrix, num_lhs::Integer, q=2)
    Q = find_range_randomly(A, num_lhs, q)
    B = Q' * A
    u_b,w,v = svd(B)
    u = Q*u_b
    u,w,v
end
