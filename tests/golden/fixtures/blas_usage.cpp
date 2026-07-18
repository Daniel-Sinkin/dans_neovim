// blas_usage.cpp -- eye-reviewed scenario: OpenBLAS-flavored numeric code.
// constexpr dimension blocks (own alignment group, no mut column), paren-init
// vectors (mut locals), a cblas call left raw, and an OPENBLAS_CONST prototype
// whose params flip exactly like const ones.
// Externals
#include <cblas.h>
// StdLib
#include <vector>
//
namespace dans::app {

auto gemm_example() -> void
{
    constexpr blasint m{2};
    constexpr blasint k{3};
    constexpr blasint n{2};
    constexpr f64 alpha{1.0};
    constexpr f64 beta{0.0};
    std::vector<f64> a(static_cast<usize>(m * k));
    std::vector<f64> b(static_cast<usize>(k * n));
    std::vector<f64> c(static_cast<usize>(m * n));
    cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, m, n, k, alpha, a.data(), k, b.data(), n, beta, c.data(), n);
}

void cblas_dscal(OPENBLAS_CONST blasint N, OPENBLAS_CONST double alpha, double *X, OPENBLAS_CONST blasint incX);

} // namespace dans::app
