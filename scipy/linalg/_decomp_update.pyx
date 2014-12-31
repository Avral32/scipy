"""
Routines for updating QR decompositions

.. versionadded: 0.16.0

"""
# 
# Copyright (C) 2014 Eric Moore
#
# A few references for Updating QR factorizations:
# 
# 1, 2, and 3 cover updates to full decompositons (q is square) and 4 and 5
# cover updates to thin (economic) decompositions (r is square). Reference 3
# additonally covers updating complete orthogonal factorizations and cholesky
# decompositions (i.e. updating R alone).
#
# 1. Golub, G. H. & Loan, C. F. van V. Matrix Computations, 3rd Ed.
#    (Johns Hopkins University Press, 1996).
#
# 2. Hammarling, S. & Lucas, C. Updating the QR factorization and the least
#    squares problem. 1-73 (The University of Manchester, 2008).
#    at <http://eprints.ma.man.ac.uk/1192/>
#
# 3. Gill, P. E., Golub, G. H., Murray, W. & Saunders, M. A. Methods for
#    modifying matrix factorizations. Math. Comp. 28, 505-535 (1974).
#
# 4. Daniel, J. W., Gragg, W. B., Kaufman, L. & Stewart, G. W.
#    Reorthogonalization and stable algorithms for updating the Gram-Schmidt QR
#    factorization. Math. Comput. 30, 772-795 (1976).
#
# 5. Reichel, L. & Gragg, W. B. Algorithm 686: FORTRAN Subroutines for
#    Updating the QR Decomposition. ACM Trans. Math. Softw. 16, 369–377 (1990).
# 

cimport cython
cimport libc.stdlib
cimport libc.limits as limits
from libc.math cimport sqrt, fabs, hypot
from libc.string cimport memset
cimport numpy as cnp

cdef int NPY_ANYORDER = 0  
cdef int MEMORY_ERROR = limits.INT_MAX

# These are commented out in the numpy support we cimported above.
# Here I have declared them as taking void* instead of PyArrayDescr
# and object. In this file, only NULL is passed to these parameters.
cdef extern from *:
    cnp.ndarray PyArray_CheckFromAny(object, void*, int, int, int, void*)
    cnp.ndarray PyArray_FromArray(cnp.ndarray, void*, int)

from scipy.linalg cimport blas_pointers
from scipy.linalg cimport lapack_pointers

import numpy as np

#------------------------------------------------------------------------------
# These are a set of fused type wrappers around the BLAS and LAPACK calls used. 
#------------------------------------------------------------------------------

ctypedef float complex float_complex
ctypedef double complex double_complex
ctypedef fused blas_t:
    float
    double
    float_complex
    double_complex

cdef inline blas_t* index2(blas_t* a, int* as, int i, int j) nogil:
    return a + i*as[0] + j*as[1]

cdef inline blas_t* index1(blas_t* a, int* as, int i) nogil:
    return a + i*as[0]

cdef inline blas_t* row(blas_t* a, int* as, int i) nogil:
    return a + i*as[0]

cdef inline blas_t* col(blas_t* a, int* as, int j) nogil:
    return a + j*as[1]
    
cdef inline void copy(int n, blas_t* x, int incx, blas_t* y, int incy) nogil:
    if blas_t is float:
        blas_pointers.scopy(&n, x, &incx, y, &incy) 
    elif blas_t is double:
        blas_pointers.dcopy(&n, x, &incx, y, &incy)
    elif blas_t is float_complex:
        blas_pointers.ccopy(&n, x, &incx, y, &incy)
    else:
        blas_pointers.zcopy(&n, x, &incx, y, &incy)

cdef inline void swap(int n, blas_t* x, int incx, blas_t* y, int incy) nogil:
    if blas_t is float:
        blas_pointers.sswap(&n, x, &incx, y, &incy) 
    elif blas_t is double:
        blas_pointers.dswap(&n, x, &incx, y, &incy)
    elif blas_t is float_complex:
        blas_pointers.cswap(&n, x, &incx, y, &incy)
    else:
        blas_pointers.zswap(&n, x, &incx, y, &incy)

cdef inline void scal(int n, blas_t a, blas_t* x, int incx) nogil:
    if blas_t is float:
        blas_pointers.sscal(&n, &a, x, &incx)
    elif blas_t is double:
        blas_pointers.dscal(&n, &a, x, &incx)
    elif blas_t is float_complex:
        blas_pointers.cscal(&n, &a, x, &incx)
    else:
        blas_pointers.zscal(&n, &a, x, &incx)

cdef inline void axpy(int n, blas_t a, blas_t* x, int incx,
                      blas_t* y, int incy) nogil:
    if blas_t is float:
        blas_pointers.saxpy(&n, &a, x, &incx, y, &incy)
    elif blas_t is double:
        blas_pointers.daxpy(&n, &a, x, &incx, y, &incy)
    elif blas_t is float_complex:
        blas_pointers.caxpy(&n, &a, x, &incx, y, &incy)
    else:
        blas_pointers.zaxpy(&n, &a, x, &incx, y, &incy)

cdef inline blas_t nrm2(int n, blas_t* x, int incx) nogil:
    # since dnrm2 etc are functions, we can't at present call them...
    # this is mostly cribbed from netlib's dnrm2
    cdef double norm, scale, ssq, absxi
    cdef float fnorm, fscale, fssq, fabsxi
    if blas_t is float:
        if n < 1 or incx < 1:
            fnorm = 0
        elif n == 1:
            fnorm = fabs(x[0])
        else:
            fscale = 0.0
            fssq = 1.0
    
            for k in range(n):
                if index1(x, &incx, k)[0] != 0:
                    fabsxi = fabs(index1(x, &incx, k)[0])
                    if fscale < fabsxi:
                        fssq = 1 + fssq * (fscale/fabsxi)**2
                        fscale = fabsxi
                    else:
                        fssq = fssq + (fabsxi/fscale)**2
            fnorm = fscale*sqrt(fssq)
        return fnorm
    elif blas_t is double:
        if n < 1 or incx < 1:
            norm = 0
        elif n == 1:
            norm = fabs(x[0])
        else:
            scale = 0.0
            ssq = 1.0
    
            for k in range(n):
                if index1(x, &incx, k)[0] != 0:
                    absxi = fabs(index1(x, &incx, k)[0])
                    if scale < absxi:
                        ssq = 1 + ssq * (scale/absxi)**2
                        scale = absxi
                    else:
                        ssq = ssq + (absxi/scale)**2
            norm = scale*sqrt(ssq)
        return norm
    elif blas_t is float_complex:
        if n < 1 or incx < 1:
            fnorm = 0
        elif n == 1:
            fnorm = hypot(x[0].real, x[0].imag)
        else:
            fscale = 0.0
            fssq = 1.0
    
            for k in range(n):
                if index1(x, &incx, k)[0] != 0:
                    fabsxi = hypot(index1(x, &incx, k)[0].real, index1(x, &incx, k)[0].imag)
                    if fscale < fabsxi:
                        fssq = 1 + fssq * (fscale/fabsxi)**2
                        fscale = fabsxi
                    else:
                        fssq = fssq + (fabsxi/fscale)**2
            fnorm = fscale*sqrt(fssq)
        return fnorm
    else:
        if n < 1 or incx < 1:
            norm = 0
        elif n == 1:
            norm = hypot(x[0].real, x[0].imag)
        else:
            scale = 0.0
            ssq = 1.0
    
            for k in range(n):
                if index1(x, &incx, k)[0] != 0:
                    absxi = hypot(index1(x, &incx, k)[0].real, index1(x, &incx, k)[0].imag)
                    if scale < absxi:
                        ssq = 1 + ssq * (scale/absxi)**2
                        scale = absxi
                    else:
                        ssq = ssq + (absxi/scale)**2
            norm = scale*sqrt(ssq)
        return norm

cdef inline void lartg(blas_t* a, blas_t* b, blas_t* c, blas_t* s) nogil:
    cdef blas_t g
    if blas_t is float:
        lapack_pointers.slartg(a, b, c, s, &g)
    elif blas_t is double:
        lapack_pointers.dlartg(a, b, c, s, &g)
    elif blas_t is float_complex:
        lapack_pointers.clartg(a, b, <float*>c, s, &g)
    else:
        lapack_pointers.zlartg(a, b, <double*>c, s, &g)
    # make this function more like the BLAS drotg
    a[0] = g
    b[0] = 0

cdef inline void rot(int n, blas_t* x, int incx, blas_t* y, int incy,
                     blas_t c, blas_t s) nogil:
    if blas_t is float:
        blas_pointers.srot(&n, x, &incx, y, &incy, &c, &s) 
    elif blas_t is double:
        blas_pointers.drot(&n, x, &incx, y, &incy, &c, &s)
    elif blas_t is float_complex:
        lapack_pointers.crot(&n, x, &incx, y, &incy, <float*>&c, &s)
    else:
        lapack_pointers.zrot(&n, x, &incx, y, &incy, <double*>&c, &s)

cdef inline void larfg(int n, blas_t* alpha, blas_t* x, int incx,
                       blas_t* tau) nogil:
    if blas_t is float:
        lapack_pointers.slarfg(&n, alpha, x, &incx, tau)
    elif blas_t is double:
        lapack_pointers.dlarfg(&n, alpha, x, &incx, tau)
    elif blas_t is float_complex:
        lapack_pointers.clarfg(&n, alpha, x, &incx, tau)
    else:
        lapack_pointers.zlarfg(&n, alpha, x, &incx, tau)

cdef inline void larf(char* side, int m, int n, blas_t* v, int incv, blas_t tau,
    blas_t* c, int ldc, blas_t* work) nogil:
    if blas_t is float:
        lapack_pointers.slarf(side, &m, &n, v, &incv, &tau, c, &ldc, work)
    elif blas_t is double:
        lapack_pointers.dlarf(side, &m, &n, v, &incv, &tau, c, &ldc, work)
    elif blas_t is float_complex:
        lapack_pointers.clarf(side, &m, &n, v, &incv, &tau, c, &ldc, work)
    else:
        lapack_pointers.zlarf(side, &m, &n, v, &incv, &tau, c, &ldc, work)

cdef inline void ger(int m, int n, blas_t alpha, blas_t* x, int incx, blas_t* y,
        int incy, blas_t* a, int lda) nogil:
    if blas_t is float:
        blas_pointers.sger(&m, &n, &alpha, x, &incx, y, &incy, a, &lda)
    elif blas_t is double:
        blas_pointers.dger(&m, &n, &alpha, x, &incx, y, &incy, a, &lda)
    elif blas_t is float_complex:
        blas_pointers.cgeru(&m, &n, &alpha, x, &incx, y, &incy, a, &lda)
    else:
        blas_pointers.zgeru(&m, &n, &alpha, x, &incx, y, &incy, a, &lda)

cdef inline void gemv(char* trans, int m, int n, blas_t alpha, blas_t* a,
        int lda, blas_t* x, int incx, blas_t beta, blas_t* y, int incy) nogil:
    if blas_t is float:
        blas_pointers.sgemv(trans, &m, &n, &alpha, a, &lda, x, &incx, &beta,
                y, &incy)
    elif blas_t is double:
        blas_pointers.dgemv(trans, &m, &n, &alpha, a, &lda, x, &incx, &beta,
                y, &incy)
    elif blas_t is float_complex:
        blas_pointers.cgemv(trans, &m, &n, &alpha, a, &lda, x, &incx, &beta,
                y, &incy)
    else:
        blas_pointers.zgemv(trans, &m, &n, &alpha, a, &lda, x, &incx, &beta,
                y, &incy)

cdef inline void gemm(char* transa, char* transb, int m, int n, int k,
        blas_t alpha, blas_t* a, int lda, blas_t* b, int ldb, blas_t beta,
        blas_t* c, int ldc) nogil:
    if blas_t is float:
        blas_pointers.sgemm(transa, transb, &m, &n, &k, &alpha, a, &lda,
                b, &ldb, &beta, c, &ldc)
    elif blas_t is double:
        blas_pointers.dgemm(transa, transb, &m, &n, &k, &alpha, a, &lda,
                b, &ldb, &beta, c, &ldc)
    elif blas_t is float_complex:
        blas_pointers.cgemm(transa, transb, &m, &n, &k, &alpha, a, &lda,
                b, &ldb, &beta, c, &ldc)
    else:
        blas_pointers.zgemm(transa, transb, &m, &n, &k, &alpha, a, &lda,
                b, &ldb, &beta, c, &ldc)

cdef inline void trmm(char* side, char* uplo, char* transa, char* diag, int m,
        int n, blas_t alpha, blas_t* a, int lda, blas_t* b, int ldb) nogil:
    if blas_t is float:
        blas_pointers.strmm(side, uplo, transa, diag, &m, &n, &alpha, a, &lda,
                b, &ldb)
    elif blas_t is double:
        blas_pointers.dtrmm(side, uplo, transa, diag, &m, &n, &alpha, a, &lda,
                b, &ldb)
    elif blas_t is float_complex:
        blas_pointers.ctrmm(side, uplo, transa, diag, &m, &n, &alpha, a, &lda,
                b, &ldb)
    else:
        blas_pointers.ztrmm(side, uplo, transa, diag, &m, &n, &alpha, a, &lda,
                b, &ldb)

cdef inline int geqrf(int m, int n, blas_t* a, int lda, blas_t* tau,
                      blas_t* work, int lwork) nogil:
    cdef int info
    if blas_t is float:
        lapack_pointers.sgeqrf(&m, &n, a, &lda, tau, work, &lwork, &info)
    elif blas_t is double:
        lapack_pointers.dgeqrf(&m, &n, a, &lda, tau, work, &lwork, &info)
    elif blas_t is float_complex:
        lapack_pointers.cgeqrf(&m, &n, a, &lda, tau, work, &lwork, &info)
    else:
        lapack_pointers.zgeqrf(&m, &n, a, &lda, tau, work, &lwork, &info)
    return info

cdef inline int ormqr(char* side, char* trans, int m, int n, int k, blas_t* a,
    int lda, blas_t* tau, blas_t* c, int ldc, blas_t* work, int lwork) nogil:
    cdef int info = 0 
    if blas_t is float:
        lapack_pointers.sormqr(side, trans, &m, &n, &k, a, &lda, tau, c, &ldc,
                work, &lwork, &info)
    elif blas_t is double:
        lapack_pointers.dormqr(side, trans, &m, &n, &k, a, &lda, tau, c, &ldc,
                work, &lwork, &info)
    elif blas_t is float_complex:
        lapack_pointers.cunmqr(side, trans, &m, &n, &k, a, &lda, tau, c, &ldc,
                work, &lwork, &info)
    else:
        lapack_pointers.zunmqr(side, trans, &m, &n, &k, a, &lda, tau, c, &ldc,
                work, &lwork, &info)
    return info

#------------------------------------------------------------------------------
# Utility routines
#------------------------------------------------------------------------------

cdef cnp.ndarray PyArray_FromArraySafe(cnp.ndarray arr, void* newtype, int flags):
    """In Numpy 1.5.1, Use of the NPY_F_CONTIGUOUS flag is broken when used
    with a 1D input array.  The work around is to pass NPY_C_CONTIGUOUS since
    for 1D arrays these are equivalent.  This is Numpy's gh-2287, fixed in
    9b8ff38.

    FIXME: Is it worth only applying this for numpy 1.5.1? 
    """
    if arr.ndim == 1 and (flags & cnp.NPY_F_CONTIGUOUS):
        flags = flags & ~cnp.NPY_F_CONTIGUOUS
        flags |= cnp.NPY_C_CONTIGUOUS
    return PyArray_FromArray(arr, newtype, flags)

cdef void blas_t_conj(int n, blas_t* x, int* xs) nogil:
    cdef int j
    if blas_t is float_complex or blas_t is double_complex:
        for j in range(n):
            index1(x, xs, j)[0] = index1(x, xs, j)[0].conjugate()

cdef void blas_t_2d_conj(int m, int n, blas_t* x, int* xs) nogil:
    cdef int i, j
    if blas_t is float_complex or blas_t is double_complex:
        for i in range(m):
            for j in range(n):
                index2(x, xs, i, j)[0] = index2(x, xs, i, j)[0].conjugate()

cdef blas_t blas_t_sqrt(blas_t x) nogil:
    if blas_t is float:
        return sqrt(x)
    elif blas_t is double:
        return sqrt(x)
    elif blas_t is float_complex:
        return <float_complex>sqrt(<double>((<float*>&x)[0]))
    else:
        return sqrt((<double*>&x)[0])

cdef bint blas_t_less_than(blas_t x, blas_t y) nogil:
    if blas_t is float or blas_t is double:
        return x < y
    else:
        return x.real < y.real

cdef int to_lwork(blas_t a, blas_t b) nogil:
    cdef int ai, bi
    if blas_t is float or blas_t is double:
        ai = <int>a
        bi = <int>b
    elif blas_t is float_complex:
        ai = <int>((<float*>&a)[0])
        bi = <int>((<float*>&b)[0])
    elif blas_t is double_complex:
        ai = <int>((<double*>&a)[0])
        bi = <int>((<double*>&b)[0])
    return max(ai, bi)

#------------------------------------------------------------------------------
# QR update routines start here.
#------------------------------------------------------------------------------

cdef bint reorthx(int m, int n, blas_t* q, int* qs, bint qisF, int j, blas_t* u, blas_t* s) nogil:
    # U should be all zeros on entry.
    cdef blas_t unorm, snorm, wnorm, wpnorm, sigma_max, sigma_min, rc
    cdef char* T = 'T'
    cdef char* N = 'N'
    cdef char* C = 'C'
    cdef int ss = 1
    cdef blas_t inv_root2 = <blas_t>sqrt(2)

    # u starts out as the jth basis vector.
    u[j] = 1

    # s = Q.T.dot(u) = jth row of Q.
    copy(n, row(q, qs, j), qs[1], s, 1)
    blas_t_conj(n, s, &ss)

    # make u be the part of u that is not in span(q)
    # i.e. u -= q.dot(s)
    if qisF:
        gemv(N, m, n, -1, q, qs[1], s, 1, 1, u, 1)
    else:
        gemv(T, n, m, -1, q, n, s, 1, 1, u, 1)
    wnorm = nrm2(m, u, 1)

    if blas_t_less_than(inv_root2, wnorm):
        scal(m, 1/wnorm, u, 1)
        s[n] = wnorm
        return True

    # if the above check failed, try one reorthogonalization
    if qisF:
        if blas_t is float or blas_t is double:
            gemv(T, m, n, 1, q, qs[1], u, 1, 0, s+n, 1)
        else:
            gemv(C, m, n, 1, q, qs[1], u, 1, 0, s+n, 1)
        gemv(N, m, n, -1, q, qs[1], s+n, 1, 1, u, 1)
    else:
        if blas_t is float or blas_t is double:
            gemv(N, n, m, 1, q, n, u, 1, 0, s+n, 1)
        else:
            blas_t_conj(m, u, &ss)
            gemv(N, n, m, 1, q, n, u, 1, 0, s+n, 1)
            blas_t_conj(m, u, &ss)
            blas_t_conj(n, s+n, &ss)
        gemv(T, n, m, -1, q, n, s+n, 1, 1, u, 1)
        
    wpnorm = nrm2(m, u, 1) 
    
    if blas_t_less_than(wpnorm, wnorm/inv_root2): # u lies in span(q) 
        scal(m, 0, u, 1)
        axpy(n, 1, s, 1, s+n, 1)
        s[n] = 0
        return False
    scal(m, 1/wpnorm, u, 1)
    axpy(n, 1, s, 1, s+n, 1)
    s[n] = wpnorm
    return True

cdef int thin_qr_row_delete(int m, int n, blas_t* q, int* qs, bint qisF, blas_t* r, int* rs, int k, int p_eco, int p_full) nogil:
    cdef int i, j, argmin_row_norm 
    cdef size_t usize = (m + 3*n + 1) * sizeof(blas_t)
    cdef blas_t* s
    cdef blas_t* u
    cdef blas_t* s1
    cdef int us[1]
    cdef int ss[1]
    cdef blas_t c, sn, min_row_norm, row_norm

    u = <blas_t*>libc.stdlib.malloc(usize)
    if not u:
        return MEMORY_ERROR
    s = u + m
    ss[0] = 1
    ss[1] = 0
    us[0] = 1
    us[1] = 0

    for i in range(p_eco):
        memset(u, 0, usize)
        # permute q such that row k is the last row.
        if k != m-1:
            for j in range(k, m-1):
                swap(n, row(q, qs, j), qs[1], row(q, qs, j+1), qs[1])

        if not reorthx(m, n, q, qs, qisF, m-1, u, s):
            # if we get here it means that this basis vector lies in span(q).
            # we want to use s[:n+1] but we need a vector into null(q)
            # find the row of q with the smallest norm and try that. (Daniel, p785)
            min_row_norm = nrm2(n, row(q, qs, 0), qs[1])
            argmin_row_norm = 0
            for j in range(1, m):
                row_norm = nrm2(n, row(q, qs, j), qs[1])
                if blas_t_less_than(row_norm, min_row_norm):
                    min_row_norm = row_norm
                    argmin_row_norm = j
            memset(u, 0, m*sizeof(blas_t))
            if not reorthx(m, n, q, qs, qisF, argmin_row_norm, u, s+n+1):
                # failed, quit.
                libc.stdlib.free(u)
                return 0

        memset(s+2*n, 0, n*sizeof(blas_t))

        # what happens here...
        for j in range(n-1, -1, -1):
            lartg(index1(s, ss, n), index1(s, ss, j), &c, &sn)
            rot(n-j, index1(s+2*n, ss, j), ss[0], index2(r, rs,j, j), rs[1], c, sn)
            rot(m-1, u, us[0], col(q, qs, j), qs[0], c, sn.conjugate())
        m -= 1

    libc.stdlib.free(u)

    if p_full:
        qr_block_row_delete(m, n, q, qs, r, rs, k, p_full)
    return 1

cdef void qr_block_row_delete(int m, int n, blas_t* q, int* qs,
                              blas_t* r, int* rs, int k, int p) nogil:
    cdef int i, j
    cdef blas_t c,s
    cdef blas_t* W
    cdef int* ws

    if k != 0:
        for j in range(k, 0, -1):
            swap(m, row(q, qs, j+p-1), qs[1], row(q, qs, j-1), qs[1])
    
    # W is the block of rows to be removed from q, has shape, (p,m)
    W = q
    ws = qs

    for j in range(p):
        blas_t_conj(m, row(W, ws, j), &ws[1])

    for i in range(p):
        for j in range(m-2, i-1, -1):
            lartg(index2(W, ws, i, j), index2(W, ws, i, j+1), &c, &s)
            
            # update W
            if i+1 < p:
                rot(p-i-1, index2(W, ws, i+1, j), ws[0],
                    index2(W, ws, i+1, j+1), ws[0], c, s)

            # update r if there is a nonzero row.
            if j-i < n:
                rot(n-j+i, index2(r, rs, j, j-i), rs[1],
                    index2(r, rs, j+1, j-i), rs[1], c, s)

            # update q
            rot(m-p, index2(q, qs, p, j), qs[0], index2(q, qs, p, j+1), qs[0],
                c, s.conjugate())

cdef void qr_col_delete(int m, int o, int n, blas_t* q, int* qs, blas_t* r,
                        int* rs, int k) nogil:
    """
        Here we support both full and economic decomposition, q is (m,o), and r
        is (o, n).
    """
    cdef int j
    cdef int limit = min(o, n)

    for j in range(k, n-1):
        copy(limit, col(r, rs, j+1), rs[0], col(r, rs, j), rs[0])

    hessenberg_qr(m, n-1, q, qs, r, rs, k)

cdef int qr_block_col_delete(int m, int o, int n, blas_t* q, int* qs,
                              blas_t* r, int* rs, int k, int p) nogil:
    """
        Here we support both full and economic decomposition, q is (m,o), and r
        is (o, n).
    """
    cdef int j
    cdef int limit = min(o, n)
    cdef blas_t* work
    cdef int worksize = max(m, n)

    work = <blas_t*>libc.stdlib.malloc(worksize*sizeof(blas_t))
    if not work:
        return MEMORY_ERROR

    # move the columns to removed to the end
    for j in range(k, n-p):
        copy(limit, col(r, rs, j+p), rs[0], col(r, rs, j), rs[0])

    p_subdiag_qr(m, o, n-p, q, qs, r, rs, k, p, work)

    libc.stdlib.free(work)
    return 0

cdef void thin_qr_row_insert(int m, int n, blas_t* q, int* qs, blas_t* r,
        int* rs, blas_t* u, int* us, int k) nogil:
    cdef int j
    cdef blas_t c, s

    for j in range(n):
        lartg(index2(r, rs, j, j), index1(u, us, j), &c, &s)
        rot(n-j-1, index2(r, rs, j, j+1), rs[1], index1(u, us, j+1), us[0],
                c, s)
        rot(m, col(q, qs, j), qs[0], col(q, qs, n), qs[0], c, s.conjugate())

    # permute q
    for j in range(m-1, k, -1):
        swap(n, row(q, qs, j), qs[1], row(q, qs, j-1), qs[1])

cdef void qr_row_insert(int m, int n, blas_t* q, int* qs, blas_t* r, int* rs,
                        int k) nogil:
    cdef int j
    cdef blas_t c, s
    cdef int limit = min(m-1, n)

    for j in range(limit):
        lartg(index2(r, rs, j, j), index2(r, rs, m-1, j), &c, &s)
        rot(n-j-1, index2(r, rs, j, j+1), rs[1], index2(r, rs, m-1, j+1), rs[1],
                c, s)
        rot(m, col(q, qs, j), qs[0], col(q, qs, m-1), qs[0], c, s.conjugate())

    # permute q 
    for j in range(m-1, k, -1):
        swap(m, row(q, qs, j), qs[1], row(q, qs, j-1), qs[1])

cdef int thin_qr_block_row_insert(int m, int n, blas_t* q, int* qs, blas_t* r,
        int* rs, blas_t* u, int* us, int k, int p) nogil:
    # as below this should someday call lapack's xtpqrt.
    cdef int j
    cdef blas_t rjj, tau
    cdef blas_t* work
    cdef char* T = 'T'
    cdef char* N = 'N'
    cdef size_t worksize = m * sizeof(blas_t)

    work = <blas_t*>libc.stdlib.malloc(worksize)
    if not work:
        return MEMORY_ERROR
   
    # possible FIX
    # as this is written it requires F order q, r, and u.  But thats not 
    # strictly necessary. C order should also work too with a little fiddling.
    for j in range(n):
        rjj = index2(r, rs, j, j)[0]
        larfg(p+1, &rjj, col(u, us, j), us[0], &tau)

        # here we apply the reflector by hand instead of calling larf
        # since we need to apply it to a stack of r atop u, and these
        # are separate.  This also permits the reflector to always be
        # p+1 long, rather than having a max of n+p.
        copy(n-j, index2(r, rs, j, j+1), rs[1], work, 1)
        blas_t_conj(p, col(u, us, j), &us[0])
        gemv(T, p, n-j-1, 1, index2(u, us, 0, j+1), us[1], col(u, us, j), us[0],
             1, work, 1)
        blas_t_conj(p, col(u, us, j), &us[0])
        ger(p, n-j-1, -tau.conjugate(), col(u, us, j), us[0], work, 1,
            index2(u, us, 0, j+1), us[1])
        axpy(n-j-1, -tau.conjugate(), work, 1, index2(r, rs, j, j+1), rs[1])
        index2(r, rs, j, j)[0] = rjj
        
        # now apply this reflector to q 
        copy(m, col(q, qs, j), qs[0], work, 1)
        gemv(N, m, p, 1, index2(q, qs, 0, n), qs[1], col(u, us, j), us[0],
             1, work, 1)
        blas_t_conj(p, col(u, us, j), &us[0])
        ger(m, p, -tau, work, 1, col(u, us, j), us[0],
            index2(q, qs, 0, n), qs[1])
        axpy(m, -tau, work, 1, col(q, qs, j), qs[0])

    # permute the rows of q, work columnwise, since q is fortran order
    if k != m-p:
        for j in range(n):
            copy(m-k-p, index2(q, qs, k, j), qs[0], work, 1)
            copy(p, index2(q, qs, m-p, j), qs[0], index2(q, qs, k, j), qs[0])
            copy(m-k-p, work, 1, index2(q, qs, k+p, j), qs[0])

    libc.stdlib.free(work)

cdef int qr_block_row_insert(int m, int n, blas_t* q, int* qs,
                              blas_t* r, int* rs, int k, int p) nogil:
    # this should someday call lapack's xtpqrt (requires lapack >= 3.4
    # released nov 11). RHEL6's atlas doesn't seem to have it.
    # On input this looks something like this:
    # q = x x x x 0 0 0  r = x x x
    #     x x x x 0 0 0      0 x x
    #     x x x x 0 0 0      0 0 x
    #     x x x x 0 0 0      0 0 0
    #     0 0 0 0 1 0 0      * * *
    #     0 0 0 0 0 1 0      * * *
    #     0 0 0 0 0 0 1      * * *
    #
    # The method will be to apply a series of reflectors to re triangularize r.
    # followed by permuting the rows of q to put the new rows in the requested
    # position.
    cdef int j, hlen
    cdef blas_t rjj, tau
    cdef blas_t* work
    cdef char* sideL = 'L'
    cdef char* sideR = 'R'
    # for tall or sqr + rows should be n. for fat + rows should be new m
    cdef int limit = min(m, n)

    work = <blas_t*>libc.stdlib.malloc(max(m,n)*sizeof(blas_t))
    if not work:
        return MEMORY_ERROR

    for j in range(limit):
        rjj = index2(r, rs, j, j)[0]
        hlen = m-j
        larfg(hlen, &rjj, index2(r, rs, j+1, j), rs[0], &tau)
        index2(r, rs, j, j)[0] = 1
        if j+1 < n:
            larf(sideL, hlen, n-j-1, index2(r, rs, j, j), rs[0],
                    tau.conjugate(), index2(r, rs, j, j+1), rs[1], work)
        larf(sideR, m, hlen, index2(r, rs, j, j), rs[0], tau,
                index2(q, qs, 0, j), qs[1], work)
        memset(index2(r, rs, j, j), 0, hlen*sizeof(blas_t))
        index2(r, rs, j, j)[0] = rjj

    # permute the rows., work columnwise, since q is fortran order
    if k != m-p:
        for j in range(m):
            copy(m-k-p, index2(q, qs, k, j), qs[0], work, 1)
            copy(p, index2(q, qs, m-p, j), qs[0], index2(q, qs, k, j), qs[0])
            copy(m-k-p, work, 1, index2(q, qs, k+p, j), qs[0])

    libc.stdlib.free(work)
    return 0

cdef void qr_col_insert(int m, int n, blas_t* q, int* qs, blas_t* r, int* rs,
                        int k) nogil:
    cdef int j
    cdef blas_t c, s, temp, tau
    cdef blas_t* work
    
    for j in range(m-2, k-1, -1):
        lartg(index2(r, rs, j, k), index2(r, rs, j+1, k), &c, &s)

        # update r if j is a nonzero row
        if j+1 < n:
            rot(n-j-1, index2(r, rs, j, j+1), rs[1],
                    index2(r, rs, j+1, j+1), rs[1], c, s)

        # update the columns of q
        rot(m, col(q, qs, j), qs[0], col(q, qs, j+1), qs[0], c, s.conjugate())

cdef int qr_block_col_insert(int m, int n, blas_t* q, int* qs,
                              blas_t* r, int* rs, int k, int p) nogil:
    cdef int i, j
    cdef blas_t c, s
    cdef blas_t* tau = NULL
    cdef blas_t* work = NULL
    cdef int info, lwork
    cdef char* side = 'R'
    cdef char* trans = 'N'

    if m >= n:
        # if m > n, r looks like this.
        # x x x x x x x x x x
        #   x x x x x x x x x
        #     x x x x x x x x
        #       x x x x x x x
        #       x x x   x x x
        #       x x x     x x
        #       x x x       x
        #       x x x 
        #       x x x 
        #       x x x 
        #       x x x 
        #       x x x 
        #
        # First zero the lower part of the new columns using a qr.  

        # query the workspace, 
        info = geqrf(m-n+p, p, index2(r, rs, n-p, k), rs[1], tau, &c, -1)
        info = ormqr(side, trans, m, m-(n-p), p, index2(r, rs, n-p, k), rs[1],
                tau, index2(q, qs, 0, n-p), qs[1], &s, -1)

        # we're only doing one allocation, so use the larger
        lwork = to_lwork(c, s)

        # allocate the workspace + tau
        work = <blas_t*>libc.stdlib.malloc((lwork+min(m-n+p, p))*sizeof(blas_t))
        if not work:
            return MEMORY_ERROR
        tau = work + lwork

        # qr
        info = geqrf(m-n+p, p, index2(r, rs, n-p, k), rs[1], tau, work, lwork)
        if info < 0: 
            return libc.stdlib.abs(info)

        # apply the Q from this small qr to the last (m-(n-p)) columns of q.
        info = ormqr(side, trans, m, m-(n-p), p, index2(r, rs, n-p, k), rs[1],
                tau, index2(q, qs, 0, n-p), qs[1], work, lwork)
        if info < 0:
            return info

        libc.stdlib.free(work)

        # zero the reflectors since we're done with them
        # memset can be used here, since r is always fortan order
        for j in range(p):
            memset(index2(r, rs, n-p+1+j, k+j), 0, (m-(n-p+1+j))*sizeof(blas_t))

        # now we have something that looks like 
        # x x x x x x x x x x
        #   x x x x x x x x x
        #     x x x x x x x x
        #       x x x x x x x
        #       x x x   x x x
        #       x x x     x x
        #       x x x       x
        #       x x x         
        #       0 x x        
        #       0 0 x         
        #       0 0 0 
        #       0 0 0 
        #
        # and the rest of the columns need to be eliminated using rotations.

        for i in range(p):
            for j in range(n-p+i-1, k+i-1, -1):
                lartg(index2(r, rs, j, k+i), index2(r, rs, j+1, k+i), &c, &s)
                if j+1 < n:
                    rot(n-k-i-1, index2(r, rs, j, k+i+1), rs[1],
                            index2(r, rs, j+1, k+i+1), rs[1], c, s)
                rot(m, col(q, qs, j), qs[0], col(q, qs, j+1), qs[0],
                        c, s.conjugate())
    else: 
        # this case we can only uses givens rotations.
        for i in range(p):
            for j in range(m-2, k+i-1, -1):
                lartg(index2(r, rs, j, k+i), index2(r, rs, j+1, k+i), &c, &s)
                if j+1 < n:
                    rot(n-k-i-1, index2(r, rs, j, k+i+1), rs[1],
                            index2(r, rs, j+1, k+i+1), rs[1], c, s)
                rot(m, col(q, qs, j), qs[0], col(q, qs, j+1), qs[0],
                        c, s.conjugate())
    return 0

cdef void thin_qr_rank_1_update(int m, int n, blas_t* q, int* qs, bint qisF, 
    blas_t* r, int* rs, blas_t* u, int* us, blas_t* v, int* vs, blas_t* s,
    int* ss) nogil:
    """Assume that q is (M,N) and either C or F contiguous, r is (N,N), u is M,
       and V is N.  s is a 2*n work array.
    """
    cdef int j, info
    cdef blas_t c, sn, rlast, t, rcond = 0.0
    
    info = reorth(m, n, q, qs, qisF, u, us, s, &rcond)

    # reduce s with givens, using u as the n+1 column of q
    # do the first one since the rots will be different.
    lartg(index1(s, ss, n-1), index1(s, ss, n), &c, &sn)
    t = index2(r, rs, n-1, n-1)[0] 
    rlast = -t * sn.conjugate()
    index2(r, rs, n-1, n-1)[0] = t * c
    rot(m, col(q, qs, n-1), qs[0], u, us[0], c, sn.conjugate())

    for j in range(n-2, -1, -1):
        lartg(index1(s, ss, j), index1(s, ss, j+1), &c, &sn)
        rot(n-j, index2(r, rs, j, j), rs[1],
                index2(r, rs, j+1, j), rs[1], c, sn)
        rot(m, col(q, qs, j), qs[0], col(q, qs, j+1), qs[0], c, sn.conjugate())

    # add v to the first row of r
    blas_t_conj(n, v, vs)
    axpy(n, s[0],  v, vs[0], row(r, rs, 0), rs[1])

    # now r is upper hessenberg with the only value in the last row stored in 
    # rlast (This is very similar to hessenberg_qr below, but this loop ends 
    # at n-1 instead of n)
    for j in range(n-1):
        lartg(index2(r, rs, j, j), index2(r, rs, j+1, j), &c, &sn)
        rot(n-j-1, index2(r, rs, j, j+1), rs[1],
                index2(r, rs, j+1, j+1), rs[1], c, sn)
        rot(m, col(q, qs, j), qs[0], col(q, qs, j+1), qs[0], c, sn.conjugate())

    # handle the extra value in rlast
    lartg(index2(r, rs, n-1, n-1), &rlast, &c, &sn)
    rot(m, col(q, qs, n-1), qs[0], u, us[0], c, sn.conjugate())

cdef void thin_qr_rank_p_update(int m, int n, int p, blas_t* q, int* qs,
    bint qisF, blas_t* r, int* rs, blas_t* u, int* us, blas_t* v, int* vs,
    blas_t* s, int* ss) nogil:
    """Assume that q is (M,N) and either C or F contiguous, r is (N,N), u is
       (M,p) and V is (N,p).  s is a 2*n work array.
    """
    cdef int j

    for j in range(p):
        thin_qr_rank_1_update(m, n, q, qs, qisF, r, rs, col(u, us, j), us,
                              col(v, vs, j), vs, s, ss)
  
cdef void qr_rank_1_update(int m, int n, blas_t* q, int* qs, blas_t* r, int* rs,
                           blas_t* u, int* us, blas_t* v, int* vs) nogil:
    """ here we will assume that the u = Q.T.dot(u) and not the bare u.
        if A is MxN then q is MxM, r is MxN, u is M and v is N.
        e.g. currently assuming full matrices.
    """
    cdef int j
    cdef blas_t c, s

    # The technique here is to reduce u to a series of givens rotations followed
    # by a scalar e.g. [u1,u2,u3] --> [u,0,0].  Applying these rotations to r as
    # we go.  Then we will have the update be adding v scaled by the remainder
    # of u to the first row of r, which will be upper hessenberg due to the
    # givens applied to reduce u. We then reduce the upper hessenberg r to upper
    # triangular.

    for j in range(m-2, -1, -1):
        lartg(index1(u, us, j), index1(u, us, j+1), &c, &s)

        # update jth and (j+1)th rows of r.
        if n-j > 0:
            rot(n-j, index2(r, rs, j, j), rs[1], index2(r, rs, j+1, j), rs[1], c, s)

        # update jth and (j+1)th cols of q.
        rot(m, col(q, qs, j), qs[0], col(q, qs, j+1), qs[0], c, s.conjugate())

    # add v to the first row
    blas_t_conj(n, v, vs)
    axpy(n, u[0],  v, vs[0], row(r, rs, 0), rs[1])
    
    # return to q, r form
    hessenberg_qr(m, n, q, qs, r, rs, 0)
    # no return, return q, r from python driver.

cdef int qr_rank_p_update(int m, int n, int p, blas_t* q, int* qs, blas_t* r,
                        int* rs, blas_t* u, int* us, blas_t* v, int* vs) nogil:
    cdef int i, j
    cdef blas_t c, s
    cdef blas_t* tau = NULL
    cdef blas_t* work = NULL
    cdef int info, lwork
    cdef char* sideR = 'R'
    cdef char* sideL = 'L'
    cdef char* uplo = 'U'
    cdef char* trans = 'N'
    cdef char* diag = 'N'

    if m > n:
        # query the workspace
        # below p_subdiag_qr will need workspace of size m, which is the
        # minimum, ormqr will also require.
        info = geqrf(m-n, p, index2(u, us, n, 0), us[1], tau, &c, -1)
        if info < 0:
            return libc.stdlib.abs(info)
        info = ormqr(sideR, trans, m, m-n, p, index2(u, us, n, 0), us[1], tau,
                index2(q, qs, 0, n), qs[1], &s, -1)
        if info < 0:
            return info
 
        # we're only doing one allocation, so use the larger
        lwork = to_lwork(c, s)

        # allocate the workspace + tau
        work = <blas_t*>libc.stdlib.malloc((lwork+min(m-n, p))*sizeof(blas_t))
        if not work:
            return MEMORY_ERROR
        tau = work + lwork

        # qr
        info = geqrf(m-n, p, index2(u, us, n, 0), us[1], tau, work, lwork)
        if info < 0:
            libc.stdlib.free(work)
            return libc.stdlib.abs(info)

        # apply the Q from this small qr to the last (m-n) columns of q.
        info = ormqr(sideR, trans, m, m-n, p, index2(u, us, n, 0), us[1], tau,
                index2(q, qs, 0, n), qs[1], work, lwork)
        if info < 0:
            libc.stdlib.free(work)
            return info

        # reduce u the rest of the way to upper triangular using givens.
        for i in range(p):
            for j in range(n+i-1, i-1, -1):
                lartg(index2(u, us, j, i), index2(u, us, j+1, i), &c, &s)
                if p-i-1:
                    rot(p-i-1, index2(u, us, j, i+1), us[1],
                            index2(u, us, j+1, i+1), us[1], c, s)
                rot(n, row(r, rs, j), rs[1], row(r, rs, j+1), rs[1], c, s)
                rot(m, col(q, qs, j), qs[0], col(q, qs, j+1), qs[0],
                        c, s.conjugate())

    else: # m == n or m < n
        # reduce u to upper triangular using givens.
        for i in range(p):
            for j in range(m-2, i-1, -1):
                lartg(index2(u, us, j, i), index2(u, us, j+1, i), &c, &s)
                if p-i-1:
                    rot(p-i-1, index2(u, us, j, i+1), us[1],
                            index2(u, us, j+1, i+1), us[1], c, s)
                rot(n, row(r, rs, j), rs[1], row(r, rs, j+1), rs[1], c, s)
                rot(m, col(q, qs, j), qs[0], col(q, qs, j+1), qs[0],
                        c, s.conjugate())

        # allocate workspace
        work = <blas_t*>libc.stdlib.malloc(n*sizeof(blas_t))
        if not work:
            return MEMORY_ERROR

    # now form UV**H and add it to R.
    # This won't fill in any more of R than we have already.
    blas_t_2d_conj(p, n, v, vs)
    trmm(sideL, uplo, trans, diag, p, n, 1, u, us[1], v, vs[1])

    # (should this be n, p length adds instead since these are fortan contig?)
    for j in range(p):
        axpy(n, 1, row(v, vs, j), vs[1], row(r, rs, j), rs[1])

    # now r has p subdiagonals, eliminate them with reflectors.
    p_subdiag_qr(m, m, n, q, qs, r, rs, 0, p, work)

    libc.stdlib.free(work)
    return 0

cdef void hessenberg_qr(int m, int n, blas_t* q, int* qs, blas_t* r, int* rs,
                        int k) nogil:
    """Reduce an upper hessenberg matrix r, to upper triangluar, starting in
       row j.  Apply these transformation to q as well. Both full and economic
       decompositions are supported here. 
    """
    cdef int j
    cdef blas_t c, s
    cdef int limit = min(m-1, n)

    for j in range(k, limit):
        lartg(index2(r, rs, j, j), index2(r, rs, j+1, j), &c, &s)

        # update the rest of r
        if j+1 < m:
            rot(n-j-1, index2(r, rs, j, j+1), rs[1],
                    index2(r, rs, j+1, j+1), rs[1], c, s) 

        # update q
        rot(m, col(q, qs, j), qs[0], col(q, qs, j+1), qs[0], c, s.conjugate())

cdef void p_subdiag_qr(int m, int o, int n, blas_t* q, int* qs, blas_t* r, int* rs,
                       int k, int p, blas_t* work) nogil:
    """ Reduce a matrix r to upper triangular form by eliminating the lower p 
        subdiagionals using reflectors. Both full and economic decompositions
        are supported here.  In either case, q is (m,o) and r is (o,n)
        
        q and r must be fortran order here, with work at least max(m,n) long.
    """
    cdef int j
    cdef int last
    cdef blas_t tau
    cdef blas_t rjj 
    cdef int limit = min(m-1, n)
    cdef char* sideR = 'R'
    cdef char* sideL = 'L'

    # R now has p subdiagonal values to be removed starting from col k.
    for j in range(k, limit):
        # length of the reflector
        last = min(p+1, o-j)
        rjj = index2(r, rs, j, j)[0]
        larfg(last, &rjj, index2(r, rs, j+1, j), rs[0], &tau)
        index2(r, rs, j, j)[0] = 1

        # apply the reflector to r if necessary
        if j+1 < n:
            larf(sideL, last, n-j-1, index2(r, rs, j, j), rs[0],
                    tau.conjugate(), index2(r, rs, j, j+1), rs[1], work)

        # apply the reflector to q
        larf(sideR, m, last, index2(r, rs, j, j), rs[0], tau,
                index2(q, qs, 0, j), qs[1], work)

        # rezero the householder vector we no longer need.
        memset(index2(r, rs, j+1, j), 0, (last-1)*sizeof(blas_t))

        # restore the rjj element
        index2(r, rs, j, j)[0] = rjj

def _reorth(cnp.ndarray q, cnp.ndarray u, rcond):
    cdef cnp.ndarray s
    cdef double rc_d
    cdef float rc_f
    cdef int m, n
    cdef void* qp
    cdef void* up
    cdef void* sp
    cdef int qs[2]
    cdef int us[2]
    cdef int ss[2]
    cdef cnp.npy_intp size
    cdef bint qisF

    if q.ndim != 2: raise ValueError('q must be 2d')
    m = q.shape[0]
    n = q.shape[1]
    if cnp.PyArray_CHKFLAGS(q, cnp.NPY_F_CONTIGUOUS):
        qisF = True
    elif cnp.PyArray_CHKFLAGS(q, cnp.NPY_C_CONTIGUOUS):
        qisF = False
    else:
        raise ValueError('q must be one segment.')
    if u.ndim != 1: raise ValueError('u must be 1d')
    if u.shape[0] != m: raise ValueError('u.shape[0] must be q.shape[0]')
    typecode = cnp.PyArray_TYPE(q)
    if cnp.PyArray_TYPE(u) != typecode:
        raise ValueError('q and u must have the same type.')

    if not (typecode == cnp.NPY_FLOAT or typecode == cnp.NPY_DOUBLE \
            or typecode == cnp.NPY_CFLOAT or typecode == cnp.NPY_CDOUBLE):
        raise ValueError('q and u must be a blas compatible type: f d F or D')

    q = validate_array(q, True)
    u = validate_array(u, True)

    qp = extract(q, qs)
    up = extract(u, us)

    size = 2*n
    s = cnp.PyArray_ZEROS(1, &size, typecode, 1)
    sp = extract(s, ss)

    if typecode == cnp.NPY_FLOAT:
        rc_f = rcond
        info = reorth(m, n, <float*>qp, qs, qisF, <float*>up, us, <float*>sp, &rc_f)
        return u, s[:n+1], rc_f, info
    if typecode == cnp.NPY_DOUBLE:
        rc_d = rcond
        info = reorth(m, n, <double*>qp, qs, qisF, <double*>up, us, <double*>sp, &rc_d)
        return u, s[:n+1], rc_d, info
    if typecode == cnp.NPY_CFLOAT:
        rc_f = rcond
        info = reorth(m, n, <float_complex*>qp, qs, qisF, <float_complex*>up, us, <float_complex*>sp, <float_complex*>&rc_f)
        return u, s[:n+1], rc_f, info
    if typecode == cnp.NPY_CDOUBLE:
        rc_d = rcond
        info = reorth(m, n, <double_complex*>qp, qs, qisF, <double_complex*>up, us, <double_complex*>sp, <double_complex*>&rc_d)
        return u, s[:n+1], rc_d, info

cdef int reorth(int m, int n, blas_t* q, int* qs, bint qisF, blas_t* u,
                int* us, blas_t* s, blas_t* RCOND) nogil:
    """Given a (m,n) matrix q with orthonormal columns and a (m,) vector u,
       find vectors s, w and scalar p such that u = Qs + pw where w is of unit
       length and orthogonal to the columns of q.

       FIX comment on return values, and RCOND 

       The method used for orthogonalizing u against q is described in [5]
       listed in the file header.
    """
    cdef blas_t unorm, snorm, wnorm, wpnorm, sigma_max, sigma_min, rc
    cdef char* T = 'T'
    cdef char* N = 'N'
    cdef char* C = 'C'
    cdef int ss = 1
    cdef blas_t inv_root2 = <blas_t>sqrt(2)

    # normalize u
    unorm = nrm2(m, u, us[0])
    scal(m, 1/unorm, u, us[0])

    # decompose u into q's columns.
    if qisF:
        if blas_t is float or blas_t is double:
            gemv(T, m, n, 1, q, qs[1], u, us[0], 0, s, 1)
        else:
            gemv(C, m, n, 1, q, qs[1], u, us[0], 0, s, 1)
    else:
        if blas_t is float or blas_t is double:
            gemv(N, n, m, 1, q, n, u, us[0], 0, s, 1)
        else:
            blas_t_conj(m, u, us)
            gemv(N, n, m, 1, q, n, u, us[0], 0, s, 1)
            blas_t_conj(m, u, us)
            blas_t_conj(n, s, &ss)

    # sigma_max is the largest singular value of q augmented with u/unorm
    snorm = nrm2(n, s, 1)
    sigma_max = blas_t_sqrt(1 + snorm)

    # make u be the part of u that is not in span(q)
    # i.e. u -= q.dot(s)
    if qisF:
        gemv(N, m, n, -1, q, qs[1], s, 1, 1, u, us[0])
    else:
        gemv(T, n, m, -1, q, n, s, 1, 1, u, us[0])
    wnorm = nrm2(m, u, us[0])

    # sigma_min is the smallest singular value of q qugmented with u/unorm
    # the others are == 1, since q is orthonormal.
    sigma_min = wnorm / sigma_max
    rc = sigma_min / sigma_max

    # check the conditioning of the problem.
    if blas_t_less_than(rc, RCOND[0]):
        RCOND[0] = rc
        return 2
    RCOND[0] = rc

    if blas_t_less_than(inv_root2, wnorm):
        scal(m, 1/wnorm, u, us[0])
        scal(n, unorm, s, 1)
        s[n] = unorm*wnorm
        return 0

    # if the above check failed, try one reorthogonalization
    if qisF:
        if blas_t is float or blas_t is double:
            gemv(T, m, n, 1, q, qs[1], u, us[0], 0, s+n, 1)
        else:
            gemv(C, m, n, 1, q, qs[1], u, us[0], 0, s+n, 1)
        gemv(N, m, n, -1, q, qs[1], s+n, 1, 1, u, us[0])
    else:
        if blas_t is float or blas_t is double:
            gemv(N, n, m, 1, q, n, u, us[0], 0, s+n, 1)
        else:
            blas_t_conj(m, u, us)
            gemv(N, n, m, 1, q, n, u, us[0], 0, s+n, 1)
            blas_t_conj(m, u, us)
            blas_t_conj(n, s+n, &ss)
        gemv(T, n, m, -1, q, n, s+n, 1, 1, u, us[0])
        
    wpnorm = nrm2(m, u, us[0]) 
    
    if blas_t_less_than(wpnorm, wnorm/inv_root2): # u lies in span(q) 
        scal(m, 0, u, us[0])
        axpy(n, 1, s, 1, s+n, 1)
        scal(n, unorm, s, 1)
        s[n] = 0
        return 1
    scal(m, 1/wpnorm, u, us[0])
    axpy(n, 1, s, 1, s+n, 1)
    scal(n, unorm, s, 1)
    s[n] = wpnorm*unorm
    return 0

def _form_qTu(object a, object b):
    """ this function only exists to expose the cdef version below for testing
        purposes. Here we perform minimal input validation to ensure that the
        inputs meet the requirements below.
    """
    cdef cnp.ndarray q, u, qTu
    cdef int typecode
    cdef void* qTuvoid
    cdef int qTus[2]

    if not cnp.PyArray_Check(a) or not cnp.PyArray_Check(b):
        raise ValueError('Inputs must be arrays')

    q = a
    u = b
    
    typecode = cnp.PyArray_TYPE(q)
    if cnp.PyArray_TYPE(u) != typecode:
        raise ValueError('q and u must have the same type.')

    if not (typecode == cnp.NPY_FLOAT or typecode == cnp.NPY_DOUBLE \
            or typecode == cnp.NPY_CFLOAT or typecode == cnp.NPY_CDOUBLE):
        raise ValueError('q and u must be a blas compatible type: f d F or D')

    q = validate_array(q, True)
    u = validate_array(u, True)

    qTu = cnp.PyArray_ZEROS(u.ndim, u.shape, typecode, 1)
    qTuvoid = extract(qTu, qTus)
    form_qTu(q, u, qTuvoid, qTus, 0)
    return qTu

cdef form_qTu(cnp.ndarray q, cnp.ndarray u, void* qTuvoid, int* qTus,
              int k):
    """ assuming here that q and u have compatible shapes, and are the same type
        + Q is contiguous.  This function is preferable over simply calling
        np.dot for two reasons: 1) this output is always in F order, 2) no
        copies need be made if Q is complex.  Point 2 in particular makes this
        a good bit faster for complex inputs.
    """
    cdef int m = q.shape[0]
    cdef int n = q.shape[1]
    cdef int typecode = cnp.PyArray_TYPE(q)
    cdef cnp.ndarray qTu
    cdef char* T = 'T'
    cdef char* C = 'C'
    cdef char* N = 'N'
    cdef void* qvoid
    cdef void* uvoid
    cdef int qs[2]
    cdef int us[2]
    cdef int ldu

    if cnp.PyArray_CHKFLAGS(q, cnp.NPY_F_CONTIGUOUS):
        qvoid = extract(q, qs)
        if u.ndim == 1:
            uvoid = extract(u, us)
            if typecode == cnp.NPY_FLOAT:
                gemv(T, m, n, 1, <float*>qvoid, qs[1],
                        <float*>uvoid, us[0], 0, col(<float*>qTuvoid, qTus, k), qTus[0])
            if typecode == cnp.NPY_DOUBLE:
                gemv(T, m, n, 1, <double*>qvoid, qs[1],
                        <double*>uvoid, us[0], 0, col(<double*>qTuvoid, qTus, k), qTus[0])
            if typecode == cnp.NPY_CFLOAT:
                gemv(C, m, n, 1, <float_complex*>qvoid, qs[1],
                        <float_complex*>uvoid, us[0], 0,
                        col(<float_complex*>qTuvoid, qTus, k), qTus[0])
            if typecode == cnp.NPY_CDOUBLE:
                gemv(C, m, n, 1, <double_complex*>qvoid, qs[1],
                        <double_complex*>uvoid, us[0], 0,
                        col(<double_complex*>qTuvoid, qTus, k), qTus[0])
        elif u.ndim == 2:
            p = u.shape[1]
            if cnp.PyArray_CHKFLAGS(u, cnp.NPY_F_CONTIGUOUS):
                utrans = N
                uvoid = extract(u, us)
                ldu = us[1]
            elif cnp.PyArray_CHKFLAGS(u, cnp.NPY_C_CONTIGUOUS):
                utrans = T
                uvoid = extract(u, us)
                ldu = us[0]
            else:
                u = PyArray_FromArraySafe(u, NULL, cnp.NPY_F_CONTIGUOUS)
                utrans = N
                uvoid = extract(u, us)
                ldu = us[1]
            if typecode == cnp.NPY_FLOAT:
                gemm(T, utrans, m, p, m, 1, <float*>qvoid, qs[1],
                        <float*>uvoid, ldu, 0, col(<float*>qTuvoid, qTus, k), qTus[1])
            if typecode == cnp.NPY_DOUBLE:
                gemm(T, utrans, m, p, m, 1, <double*>qvoid, qs[1],
                        <double*>uvoid, ldu, 0, col(<double*>qTuvoid, qTus, k), qTus[1])
            if typecode == cnp.NPY_CFLOAT:
                gemm(C, utrans, m, p, m, 1, <float_complex*>qvoid, qs[1],
                        <float_complex*>uvoid, ldu, 0,
                        col(<float_complex*>qTuvoid, qTus, k), qTus[1])
            if typecode == cnp.NPY_CDOUBLE:
                gemm(C, utrans, m, p, m, 1, <double_complex*>qvoid, qs[1],
                        <double_complex*>uvoid, ldu, 0,
                        col(<double_complex*>qTuvoid, qTus, k), qTus[1])
    
    elif cnp.PyArray_CHKFLAGS(q, cnp.NPY_C_CONTIGUOUS):
        qvoid = extract(q, qs)
        if u.ndim == 1:
            uvoid = extract(u, us)
            if typecode == cnp.NPY_FLOAT:
                gemv(N, m, n, 1, <float*>qvoid, qs[0],
                        <float*>uvoid, us[0], 0, col(<float*>qTuvoid, qTus, k), qTus[0])
            if typecode == cnp.NPY_DOUBLE:
                gemv(N, m, n, 1, <double*>qvoid, qs[0],
                        <double*>uvoid, us[0], 0, col(<double*>qTuvoid, qTus, k), qTus[0])
            if typecode == cnp.NPY_CFLOAT:
                blas_t_conj(m, <float_complex*>uvoid, us)
                gemv(N, m, n, 1, <float_complex*>qvoid, qs[0],
                        <float_complex*>uvoid, us[0], 0,
                        col(<float_complex*>qTuvoid, qTus, k), qTus[0])
                blas_t_conj(m, col(<float_complex*>qTuvoid, qTus, k), qTus)
            if typecode == cnp.NPY_CDOUBLE:
                blas_t_conj(m, <double_complex*>uvoid, us)
                gemv(N, m, n, 1, <double_complex*>qvoid, qs[0],
                        <double_complex*>uvoid, us[0], 0,
                        col(<double_complex*>qTuvoid, qTus, k), qTus[0])
                blas_t_conj(m, col(<double_complex*>qTuvoid, qTus, k), qTus)
        elif u.ndim == 2:
            p = u.shape[1]
            if cnp.PyArray_CHKFLAGS(u, cnp.NPY_F_CONTIGUOUS):
                utrans = N
                uvoid = extract(u, us)
                ldu = us[1]
            elif cnp.PyArray_CHKFLAGS(u, cnp.NPY_C_CONTIGUOUS):
                utrans = T
                uvoid = extract(u, us)
                ldu = us[0]
            else:
                u = PyArray_FromArraySafe(u, NULL, cnp.NPY_F_CONTIGUOUS)
                utrans = N
                uvoid = extract(u, us)
                ldu = us[1]
            if typecode == cnp.NPY_FLOAT:
                gemm(N, utrans, m, p, m, 1, <float*>qvoid, qs[0],
                        <float*>uvoid, ldu, 0, col(<float*>qTuvoid, qTus, k), qTus[1])
            elif typecode == cnp.NPY_DOUBLE:
                gemm(N, utrans, m, p, m, 1, <double*>qvoid, qs[0],
                        <double*>uvoid, ldu, 0, col(<double*>qTuvoid, qTus, k), qTus[1])
            elif typecode == cnp.NPY_CFLOAT:
                blas_t_2d_conj(m, p, <float_complex*>uvoid, us)
                gemm(N, utrans, m, p, m, 1, <float_complex*>qvoid, qs[0],
                        <float_complex*>uvoid, ldu, 0,
                        col(<float_complex*>qTuvoid, qTus, k), qTus[1])
                blas_t_2d_conj(m, p, col(<float_complex*>qTuvoid, qTus, k), qTus)
            elif typecode == cnp.NPY_CDOUBLE:
                blas_t_2d_conj(m, p, <double_complex*>uvoid, us)
                gemm(N, utrans, m, p, m, 1, <double_complex*>qvoid, qs[0],
                        <double_complex*>uvoid, ldu, 0,
                        col(<double_complex*>qTuvoid, qTus, k), qTus[1])
                blas_t_2d_conj(m, p, col(<double_complex*>qTuvoid, qTus, k), qTus)
        else:
            raise ValueError('1 <= u.ndim <= 2')
    else:
        raise ValueError('q must be either F or C contig')

cdef validate_array(cnp.ndarray a, bint chkfinite):
    # here we check that a has positive strides and that its size is small
    # enough to fit in into an int, as BLAS/LAPACK require
    cdef bint copy = False
    cdef bint too_large = False
    cdef int j

    for j in range(a.ndim):
        if a.strides[j] <= 0 or \
                (a.strides[j] / a.descr.itemsize) >= limits.INT_MAX:
            copy = True
        if a.shape[j] >= limits.INT_MAX:
            raise ValueError('Input array to large for use with BLAS')

    if chkfinite:
        if not np.isfinite(a).all():
            raise ValueError('array must not contain infs or NaNs')

    if copy:
            return PyArray_FromArraySafe(a, NULL, cnp.NPY_F_CONTIGUOUS)
    return a

cdef validate_qr(object q0, object r0, bint overwrite_q, int q_order,
                 bint overwrite_r, int r_order, bint chkfinite):
    cdef cnp.ndarray Q
    cdef cnp.ndarray R
    cdef int typecode
    cdef bint economic = False

    q_order |= cnp.NPY_BEHAVED_NS | cnp.NPY_ELEMENTSTRIDES  
    r_order |= cnp.NPY_BEHAVED_NS | cnp.NPY_ELEMENTSTRIDES

    if not overwrite_q:
        q_order |= cnp.NPY_ENSURECOPY

    if not overwrite_r:
        r_order |= cnp.NPY_ENSURECOPY

    # in the interests of giving better error messages take any number of
    # dimensions here.
    Q = PyArray_CheckFromAny(q0, NULL, 0, 0, q_order, NULL)
    R = PyArray_CheckFromAny(r0, NULL, 0, 0, r_order, NULL)

    if Q.ndim != 2 or R.ndim != 2:
        raise ValueError('Q and R must be 2d')

    typecode = cnp.PyArray_TYPE(Q)

    if typecode != cnp.PyArray_TYPE(R):
        raise ValueError('q and r must have the same type')

    if not (typecode == cnp.NPY_FLOAT or typecode == cnp.NPY_DOUBLE 
            or typecode == cnp.NPY_CFLOAT or typecode == cnp.NPY_CDOUBLE):
        raise ValueError('only floatingcomplex arrays supported')

    # we support MxM MxN and MxN NxN
    if Q.shape[1] != R.shape[0]:
        raise ValueError('Q and R do not have compatible shapes')

    # so one or the other or both should be square.
    if Q.shape[0] != Q.shape[1] and R.shape[0] == R.shape[1]:
        economic = True
    elif Q.shape[0] != Q.shape[1]:
        raise ValueError('bad shapes.')

    Q = validate_array(Q, chkfinite)
    R = validate_array(R, chkfinite)

    return Q, R, typecode, Q.shape[0], R.shape[1], economic
 
cdef void* extract(cnp.ndarray a, int* as):
    if a.ndim == 2:
        as[0] = a.strides[0] / cnp.PyArray_ITEMSIZE(a)
        as[1] = a.strides[1] / cnp.PyArray_ITEMSIZE(a)
    elif a.ndim == 1:
        as[0] = a.strides[0] / cnp.PyArray_ITEMSIZE(a)
        as[1] = 0
    return cnp.PyArray_DATA(a)

@cython.embedsignature(True)
def qr_delete(Q, R, k, p=1, which='row', overwrite_qr=True, check_finite=True):
    """QR downdate on row or column deletions

    If ``A = Q R`` is the qr factorization of A, return the qr factorization
    of `A` where `p` rows or columns have been removed starting at row or
    column `k`.

    Parameters
    ----------
    Q : (M, M) or (M, N) array_like
        Unitary/orthogonal matrix from QR decomposition.
    R : (M, N) or (N, N) array_like
        Upper trianglar matrix from QR decomposition.
    k : int
        index of the first row or column to delete.
    p : int, optional
        number of rows or columns to delete, defaults to 1.
    which: {'row', 'col'}, optional
        Determines if rows or columns will be deleted, defaults to 'row'
    overwrite_qr : bool, optional
        If True, consume Q and R, overwriting their contents with their
        downdated versions, and returning approriately sized views.  
        Defaults to True.
    check_finite : bool, optional
        Whether to check that the input matrix contains only finite numbers.
        Disabling may give a performance gain, but may result in problems
        (crashes, non-termination) if the inputs do contain infinities or NaNs.

    Returns
    -------
    Q1 : ndarray
        Updated unitary/orthogonal factor
    R1 : ndarray
        Updated upper triangular factor

    Notes
    -----
    This routine does not guarantee that the diagonal entries of `R1` are
    positive.

    .. versionadded:: 0.16.0

    Examples
    --------
    >>> from scipy import linalg
    >>> a = np.array([[  3.,  -2.,  -2.],
                      [  6.,  -9.,  -3.],
                      [ -3.,  10.,   1.],
                      [  6.,  -7.,   4.],
                      [  7.,   8.,  -6.]])
    >>> q, r = linalg.qr(a)

    Given this q, r decomposition, update q and r when 2 rows are removed.

    >>> q1, r1 = linalg.qr_delete(q, r, 2, 2, 'row', False)
    >>> q1
    array([[ 0.30942637,  0.15347579,  0.93845645],
           [ 0.61885275,  0.71680171, -0.32127338],
           [ 0.72199487, -0.68017681, -0.12681844]])
    >>> r1
    array([[  9.69535971,  -0.4125685 ,  -6.80738023],
           [  0.        , -12.19958144,   1.62370412],
           [  0.        ,   0.        ,  -0.15218213]])

    The update is equivalent, but faster than the following.

    >>> a1 = np.delete(a, slice(2,4), 0)
    >>> a1
    array([[ 3., -2., -2.],
           [ 6., -9., -3.],
           [ 7.,  8., -6.]])
    >>> q_direct, r_direct = linalg.qr(a1)

    Check that we have equivalent results:

    >>> np.dot(q1, r1)
    array([[ 3., -2., -2.],
           [ 6., -9., -3.],
           [ 7.,  8., -6.]])
    >>> np.allclose(np.dot(q1, r1), a1)
    True

    And the updated Q is still unitary:

    >>> np.allclose(np.dot(q1.T, q1), np.eye(3))
    True

    """
    cdef cnp.ndarray q1, r1
    cdef int k1 = k
    cdef int p1 = p
    cdef int p_eco, p_full
    cdef int typecode, m, n, info
    cdef int qs[2]
    cdef int rs[2]
    cdef bint economic, qisF = False 

    if which == 'row':
        q1, r1, typecode, m, n, economic = validate_qr(Q, R, overwrite_qr,
                NPY_ANYORDER, overwrite_qr, NPY_ANYORDER, check_finite)
        if not (-m <= k1 < m):
            raise ValueError('k is not a valid index')
        if k1 < 0:
            k1 += m
        if k1 + p1 > m or p1 <= 0: 
            raise ValueError('p out of range')
        if economic:
            if not cnp.PyArray_ISONESEGMENT(q1):
                q1 = PyArray_FromArraySafe(q1, NULL, cnp.NPY_F_CONTIGUOUS)
                qisF = True
            elif cnp.PyArray_CHKFLAGS(q1, cnp.NPY_F_CONTIGUOUS):
                qisF = True
            else:
                qisF = False
            if m-p >= n:
                p_eco = p1
                p_full = 0
            else:
                p_eco = m-n
                p_full = p1 - p_eco
            if typecode == cnp.NPY_FLOAT:
                info = thin_qr_row_delete(m, n, <float*>extract(q1, qs), qs, qisF,
                    <float*>extract(r1, rs), rs, k1, p_eco, p_full)
            elif typecode == cnp.NPY_DOUBLE:
                info = thin_qr_row_delete(m, n, <double*>extract(q1, qs), qs, qisF,
                    <double*>extract(r1, rs), rs, k1, p_eco, p_full)
            elif typecode == cnp.NPY_CFLOAT:
                info = thin_qr_row_delete(m, n, <float_complex*>extract(q1, qs), qs, qisF,
                    <float_complex*>extract(r1, rs), rs, k1, p_eco, p_full)
            else:  #  cnp.NPY_CDOUBLE
                info = thin_qr_row_delete(m, n, <double_complex*>extract(q1, qs), qs, qisF,
                    <double_complex*>extract(r1, rs), rs, k1, p_eco, p_full)
            if info == 1:
                return q1[p_full:-p_eco, p_full:], r1[p_full:,:]
            elif info == MEMORY_ERROR:
                raise MemoryError('malloc failed')
            else:
                raise ValueError('Reorthogonalization Failed, unable to perform row deletion.')
        else:
            if typecode == cnp.NPY_FLOAT:
                qr_block_row_delete(m, n, <float*>extract(q1, qs), qs,
                    <float*>extract(r1, rs), rs, k1, p1)
            elif typecode == cnp.NPY_DOUBLE:
                qr_block_row_delete(m, n, <double*>extract(q1, qs), qs,
                    <double*>extract(r1, rs), rs, k1, p1)
            elif typecode == cnp.NPY_CFLOAT:
                qr_block_row_delete(m, n, <float_complex*>extract(q1, qs), qs,
                    <float_complex*>extract(r1, rs), rs, k1, p1)
            else:  # cnp.NPY_CDOUBLE:
                qr_block_row_delete(m, n, <double_complex*>extract(q1, qs), qs,
                    <double_complex*>extract(r1, rs), rs, k1, p1)
            return q1[p1:, p1:], r1[p1:, :]
    elif which == 'col':
        if p1 > 1:
            q1, r1, typecode, m, n, economic = validate_qr(Q, R, overwrite_qr,
                    cnp.NPY_F_CONTIGUOUS, overwrite_qr, cnp.NPY_F_CONTIGUOUS,
                    check_finite)
        else:
            q1, r1, typecode, m, n, economic = validate_qr(Q, R, overwrite_qr,
                    NPY_ANYORDER, overwrite_qr, NPY_ANYORDER, check_finite)
        o = n if economic else m
        if not (-n <= k1 < n):
            raise ValueError('k is not a valid index')
        if k1 < 0:
            k1 += n
        if k1 + p1 > n or p1 <= 0:
            raise ValueError('p out of range')

        if p1 == 1:
            if typecode == cnp.NPY_FLOAT:
                qr_col_delete(m, o, n, <float*>extract(q1, qs), qs, 
                    <float*>extract(r1, rs), rs, k1)
            elif typecode == cnp.NPY_DOUBLE:
                qr_col_delete(m, o, n, <double*>extract(q1, qs), qs, 
                    <double*>extract(r1, rs), rs, k1)
            elif typecode == cnp.NPY_CFLOAT:
                qr_col_delete(m, o, n, <float_complex*>extract(q1, qs), qs,
                    <float_complex*>extract(r1, rs), rs, k1)
            else:  # cnp.NPY_CDOUBLE:
                qr_col_delete(m, o, n, <double_complex*>extract(q1, qs), qs,
                    <double_complex*>extract(r1, rs), rs, k1)
        else:
            if typecode == cnp.NPY_FLOAT:
                info = qr_block_col_delete(m, o, n, <float*>extract(q1, qs), qs,
                    <float*>extract(r1, rs), rs, k1, p1)
            elif typecode == cnp.NPY_DOUBLE:
                info = qr_block_col_delete(m, o, n, <double*>extract(q1, qs), qs,
                    <double*>extract(r1, rs), rs, k1, p1)
            elif typecode == cnp.NPY_CFLOAT:
                info = qr_block_col_delete(m, o, n, <float_complex*>extract(q1, qs), qs,
                    <float_complex*>extract(r1, rs), rs, k1, p1)
            else:  # cnp.NPY_CDOUBLE:
                info = qr_block_col_delete(m, o, n, <double_complex*>extract(q1, qs), qs,
                    <double_complex*>extract(r1, rs), rs, k1, p1)
            if info == MEMORY_ERROR:
                raise MemoryError('malloc failed')
        if economic:
            return q1[:, :-p], r1[:-p, :-p]
        else:
            return q1, r1[:, :-p]
    else:
        raise ValueError("which must be either 'row' or 'col'")

@cython.embedsignature(True)
def qr_insert(Q, R, u, k, which='row', overwrite_qru=True, check_finite=True):
    """QR update on row or column insertions

    If ``A = Q R`` is the qr factorization of A, return the qr factorization
    of `A` where rows or columns have been inserted starting at row or
    column `k`.

    Parameters
    ----------
    Q : (M, M) array_like
        Unitary/orthogonal matrix from the qr decomposition of A.
    R : (M, N) array_like
        Upper triangular matrix from the qr decomposition of A.
    u : (N,), (p, N), (M,), or (M, p) array_like
        Rows or coluns to insert
    k : int
        Index before which `u` is to be inserted.
    which: {'row', 'col'}, optional
        Determines if rows or columns will be inserted, defaults to 'row'
    overwrite_qru : bool, optional
        If True, consume Q, and u, if possible, while performing the update,
        otherwise make copies as necessary. Defaults to True.
    check_finite : bool, optional
        Whether to check that the input matrix contains only finite numbers.
        Disabling may give a performance gain, but may result in problems
        (crashes, non-termination) if the inputs do contain infinities or NaNs.

    Returns
    -------
    Q1 : ndarray
        Updated unitary/orthogonal factor
    R1 : ndarray
        Updated upper triangular factor

    Notes
    -----
    This routine does not guarantee that the diagonal entries of `R1` are
    positive.

    .. versionadded:: 0.16.0

    Examples
    --------
    >>> from scipy import linalg
    >>> a = np.array([[  3.,  -2.,  -2.],
                      [  6.,  -7.,   4.],
                      [  7.,   8.,  -6.]])
    >>> q, r = linalg.qr(a)

    Given this q, r decomposition, update q and r when 2 rows are inserted.
                      
    >>> u = np.array([[  6.,  -9.,  -3.], 
                      [ -3.,  10.,   1.]])
    >>> q1, r1 = linalg.qr_insert(q, r, u, 2, 'row', False)
    >>> q1
    array([[-0.25445668,  0.02246245,  0.18146236, -0.72798806,  0.60979671],
           [-0.50891336,  0.23226178, -0.82836478, -0.02837033, -0.00828114],
           [-0.50891336,  0.35715302,  0.38937158,  0.58110733,  0.35235345],
           [ 0.25445668, -0.52202743, -0.32165498,  0.36263239,  0.65404509],
           [-0.59373225, -0.73856549,  0.16065817, -0.0063658 , -0.27595554]])
    >>> r1
    array([[-11.78982612,   6.44623587,   3.81685018],
           [  0.        , -16.01393278,   3.72202865],
           [  0.        ,   0.        ,  -6.13010256],
           [  0.        ,   0.        ,   0.        ],
           [  0.        ,   0.        ,   0.        ]])

    The update is equivalent, but faster than the following.

    >>> a1 = np.insert(a, 2, u, 0)
    >>> a1
    array([[  3.,  -2.,  -2.],
           [  6.,  -7.,   4.],
           [  6.,  -9.,  -3.],
           [ -3.,  10.,   1.],
           [  7.,   8.,  -6.]])
    >>> q_direct, r_direct = linalg.qr(a1)

    Check that we have equivalent results:

    >>> np.dot(q1, r1)
    array([[  3.,  -2.,  -2.],
           [  6.,  -7.,   4.],
           [  6.,  -9.,  -3.],
           [ -3.,  10.,   1.],
           [  7.,   8.,  -6.]])

    >>> np.allclose(np.dot(q1, r1), a1)
    True

    And the updated Q is still unitary:

    >>> np.allclose(np.dot(q1.T, q1), np.eye(5))
    True

    """
    cdef cnp.ndarray q1, r1, u1, qnew, rnew
    cdef int j, k1 = k 
    cdef int q_flags = NPY_ANYORDER
    cdef int u_flags = cnp.NPY_BEHAVED_NS | cnp.NPY_ELEMENTSTRIDES
    cdef int typecode, m, n, p, info
    cdef int qs[2]
    cdef void* rvoid
    cdef int rs[2]
    cdef int us[2]
    cdef cnp.npy_intp shape[2]
    cdef bint economic

    if which == 'row':
        q1, r1, typecode, m, n, economic = validate_qr(Q, R, True, NPY_ANYORDER,
                True, NPY_ANYORDER, check_finite)
        u1 = PyArray_CheckFromAny(u, NULL, 0, 0, u_flags, NULL)
        if cnp.PyArray_TYPE(u1) != typecode:
            raise ValueError('u must have the same type as Q and R')
        if not (-m <= k1 < m):
            raise ValueError('k is not a valid index')
        if k1 < 0:
            k1 += m

        if u1.ndim == 2:
            p = u.shape[0]
            if u.shape[1] != n:
                raise ValueError('bad size u')
        else:
            p = 1
            if u.shape[0] != n:
                raise ValueError('bad size u')

        u1 = validate_array(u1, check_finite)
        if economic:
            shape[0] = m+p
            shape[1] = n+p
            qnew = cnp.PyArray_ZEROS(2, shape, typecode, 1)
            qnew[:-p,:-p] = q1
            for j in range(p):
                qnew[m+j, n+j] = 1
            if not overwrite_qru:
                r1 = r1.copy('F')
                u1 = u1.copy('F')

            if p == 1:
                if typecode == cnp.NPY_FLOAT:
                    thin_qr_row_insert(m+p, n,
                            <float*>extract(qnew, qs), qs,
                            <float*>extract(r1, rs), rs,
                            <float*>extract(u1, us), us, k1)
                elif typecode == cnp.NPY_DOUBLE:
                    thin_qr_row_insert(m+p, n,
                            <double*>extract(qnew, qs), qs,
                            <double*>extract(r1, rs), rs,
                            <double*>extract(u1, us), us, k1)
                elif typecode == cnp.NPY_CFLOAT:
                    thin_qr_row_insert(m+p, n,
                            <float_complex*>extract(qnew, qs), qs,
                            <float_complex*>extract(r1, rs), rs,
                            <float_complex*>extract(u1, us), us, k1)
                else:  # cnp.NPY_CDOUBLE:
                    thin_qr_row_insert(m+p, n,
                            <double_complex*>extract(qnew, qs), qs,
                            <double_complex*>extract(r1, rs), rs,
                            <double_complex*>extract(u1, us), us, k1)
            else:
                if not cnp.PyArray_CHKFLAGS(r1, cnp.NPY_F_CONTIGUOUS):
                    r1 = PyArray_FromArraySafe(r1, NULL, cnp.NPY_F_CONTIGUOUS)
                if not cnp.PyArray_CHKFLAGS(u1, cnp.NPY_F_CONTIGUOUS):
                    u1 = PyArray_FromArraySafe(u1, NULL, cnp.NPY_F_CONTIGUOUS)
                if typecode == cnp.NPY_FLOAT:
                    thin_qr_block_row_insert(m+p, n,
                            <float*>extract(qnew, qs), qs,
                            <float*>extract(r1, rs), rs,
                            <float*>extract(u1, us), us, k1, p)
                elif typecode == cnp.NPY_DOUBLE:
                    thin_qr_block_row_insert(m+p, n,
                            <double*>extract(qnew, qs), qs,
                            <double*>extract(r1, rs), rs,
                            <double*>extract(u1, us), us, k1, p)
                elif typecode == cnp.NPY_CFLOAT:
                    thin_qr_block_row_insert(m+p, n,
                            <float_complex*>extract(qnew, qs), qs,
                            <float_complex*>extract(r1, rs), rs,
                            <float_complex*>extract(u1, us), us, k1, p)
                else:  # cnp.NPY_CDOUBLE:
                    thin_qr_block_row_insert(m+p, n,
                            <double_complex*>extract(qnew, qs), qs,
                            <double_complex*>extract(r1, rs), rs,
                            <double_complex*>extract(u1, us), us, k1, p)
            return qnew[:, :-p], r1
        else:
            shape[0] = m+p
            shape[1] = m+p
            qnew = cnp.PyArray_ZEROS(2, shape, typecode, 1)
            shape[1] = n
            rnew = cnp.PyArray_ZEROS(2, shape, typecode, 1)
            
            # doing this by hand is unlikely to be any quicker.
            rnew[:m,:] = r1    
            rnew[m:,:] = u1
            qnew[:-p,:-p] = q1;
            ind = np.arange(m,m+p)
            qnew[ind,ind] = 1

            if p == 1:
                if typecode == cnp.NPY_FLOAT:
                    qr_row_insert(m+p, n, <float*>extract(qnew, qs), qs,
                            <float*>extract(rnew, rs), rs, k1)
                elif typecode == cnp.NPY_DOUBLE:
                    qr_row_insert(m+p, n, <double*>extract(qnew, qs), qs,
                            <double*>extract(rnew, rs), rs, k1)
                elif typecode == cnp.NPY_CFLOAT:
                    qr_row_insert(m+p, n, <float_complex*>extract(qnew, qs), qs,
                            <float_complex*>extract(rnew, rs), rs, k1)
                else:  # cnp.NPY_CDOUBLE:
                    qr_row_insert(m+p, n, <double_complex*>extract(qnew, qs),
                            qs, <double_complex*>extract(rnew, rs), rs, k1)
            else:
                if typecode == cnp.NPY_FLOAT:
                    info = qr_block_row_insert(m+p, n,
                            <float*>extract(qnew, qs), qs,
                            <float*>extract(rnew, rs), rs, k1, p)
                elif typecode == cnp.NPY_DOUBLE:
                    info = qr_block_row_insert(m+p, n,
                            <double*>extract(qnew, qs), qs,
                            <double*>extract(rnew, rs), rs, k1, p)
                elif typecode == cnp.NPY_CFLOAT:
                    info = qr_block_row_insert(m+p, n,
                            <float_complex*>extract(qnew, qs), qs,
                            <float_complex*>extract(rnew, rs), rs, k1, p)
                else:  # cnp.NPY_CDOUBLE
                    info = qr_block_row_insert(m+p, n,
                            <double_complex*>extract(qnew, qs), qs,
                            <double_complex*>extract(rnew, rs), rs, k1, p)
                if info == MEMORY_ERROR:
                    raise MemoryError('malloc failed')
            return qnew, rnew

    elif which == 'col':
        u1 = PyArray_CheckFromAny(u, NULL, 0, 0, u_flags, NULL)
        if u1.ndim == 2:
            q_flags = cnp.NPY_F_CONTIGUOUS
        q1, r1, typecode, m, n, economic = validate_qr(Q, R, overwrite_qru,
                q_flags, True, NPY_ANYORDER, check_finite)
        if economic:
            raise ValueError('economic mode decompositions are not supported.')
        if not cnp.PyArray_ISONESEGMENT(q1):
            q1 = PyArray_FromArraySafe(q1, NULL, cnp.NPY_F_CONTIGUOUS)

        if (not overwrite_qru and cnp.PyArray_CHKFLAGS(q1, cnp.NPY_C_CONTIGUOUS)
            and (typecode == cnp.NPY_CFLOAT or typecode == cnp.NPY_CDOUBLE)):
            u_flags |= cnp.NPY_ENSURECOPY
            u1 = PyArray_FromArraySafe(u1, NULL, u_flags)

        if cnp.PyArray_TYPE(u1) != typecode:
            raise ValueError('u must have the same type as Q and R')
        if not (-n <= k1 < n):
            raise ValueError('k is not a valid index')
        if k1 < 0:
            k1 += n

        if u.shape[0] != m:
            raise ValueError('bad size u')
        if u.ndim == 2:
            p = u.shape[1]
        else:
            p = 1

        shape[0] = m
        shape[1] = n+p
        rnew = cnp.PyArray_ZEROS(2, shape, typecode, 1)

        rnew[:,:k1] = r1[:,:k1]
        rnew[:,k1+p:] = r1[:,k1:]

        u1 = validate_array(u1, check_finite)
        rvoid = extract(rnew, rs)
        if p == 1:
            form_qTu(q1, u1, rvoid, rs, k1)
        else:
            form_qTu(q1, u1, rvoid, rs, k1)
        
        if p == 1:
            if typecode == cnp.NPY_FLOAT:
                qr_col_insert(m, n+p, <float*>extract(q1, qs), qs,
                        <float*>rvoid, rs, k1)
            elif typecode == cnp.NPY_DOUBLE:
                qr_col_insert(m, n+p, <double*>extract(q1, qs), qs,
                        <double*>rvoid, rs, k1)
            elif typecode == cnp.NPY_CFLOAT:
                qr_col_insert(m, n+p, <float_complex*>extract(q1, qs), qs,
                        <float_complex*>rvoid, rs, k1)
            else:  # cnp.NPY_CDOUBLE
                qr_col_insert(m, n+p, <double_complex*>extract(q1, qs), qs,
                        <double_complex*>rvoid, rs, k1)
        else:
            if typecode == cnp.NPY_FLOAT:
                info = qr_block_col_insert(m, n+p, <float*>extract(q1, qs), qs,
                        <float*>rvoid, rs, k1, p)
            elif typecode == cnp.NPY_DOUBLE:
                info = qr_block_col_insert(m, n+p, <double*>extract(q1, qs), qs,
                        <double*>rvoid, rs, k1, p)
            elif typecode == cnp.NPY_CFLOAT:
                info = qr_block_col_insert(m, n+p, <float_complex*>extract(q1, qs),
                        qs, <float_complex*>rvoid, rs, k1, p)
            else:  # cnp.NPY_CDOUBLE:
                info = qr_block_col_insert(m, n+p, <double_complex*>extract(q1, qs), 
                        qs, <double_complex*>rvoid, rs, k1, p)
            if info != 0:
                if info > 0: 
                    raise ValueError('The {0}th argument to ?geqrf was'
                            'invalid'.format(info))
                elif info < 0:
                    raise ValueError('The {0}th argument to ?ormqr/?unmqr was'
                            'invalid'.format(abs(info)))
                elif info == MEMORY_ERROR:
                    raise MemoryError('malloc failed')
        return q1, rnew
    else:
        raise ValueError("which must be either 'row' or 'col'")

@cython.embedsignature(True)
def qr_update(Q, R, u, v, overwrite_qruv=True, check_finite=True):
    """Rank-k QR update

    If ``A = Q R`` is the qr factorization of A, return the qr factorization
    of ``A + U V**T`` for real A or ``A + U V**H`` for complex A.

    Parameters
    ----------
    Q : (M, M) or (M, N) array_like
        Unitary/orthogonal matrix from the qr decomposition of A.
    R : (M, N) or (N, N) array_like
        Upper triangular matrix from the qr decomposition of A.
    u : (M,) or (M, k) array_like
        Left update vector
    v : (N,) or (N, k) array_like
        Right update vector
    overwrite_qruv : bool, optional
        If True, consume Q, R, u, and v, if possible, while performing the
        update, otherwise make copies as necessary. Defaults to True.
    check_finite : bool, optional
        Whether to check that the input matrix contains only finite numbers.
        Disabling may give a performance gain, but may result in problems
        (crashes, non-termination) if the inputs do contain infinities or NaNs.

    Returns
    -------
    Q1 : ndarray
        Updated unitary/orthogonal factor
    R1 : ndarray
        Updated upper triangular factor

    Notes
    -----
    This routine does not guarantee that the diagonal entries of `R1` are
    real or positive.

    .. versionadded:: 0.16.0

    Examples
    --------
    >>> from scipy import linalg
    >>> a = np.array([[  3.,  -2.,  -2.],
                      [  6.,  -9.,  -3.],
                      [ -3.,  10.,   1.],
                      [  6.,  -7.,   4.],
                      [  7.,   8.,  -6.]])
    >>> q, r = linalg.qr(a)

    Given this q, r decomposition, perform a rank 1 update.

    >>> u = np.array([7., -2., 4., 3., 5.])
    >>> v = np.array([1., 3., -5.])
    >>> q_up, r_up = linalg.qr_update(q, r, u, v, False)
    >>> q_up
    array([[ 0.54073807,  0.18645997,  0.81707661, -0.02136616,  0.06902409],
           [ 0.21629523, -0.63257324,  0.06567893,  0.34125904, -0.65749222],
           [ 0.05407381,  0.64757787, -0.12781284, -0.20031219, -0.72198188],
           [ 0.48666426, -0.30466718, -0.27487277, -0.77079214,  0.0256951 ],
           [ 0.64888568,  0.23001   , -0.4859845 ,  0.49883891,  0.20253783]])
    >>> r_up
    array([[ 18.49324201,  24.11691794, -44.98940746],
           [  0.        ,  31.95894662, -27.40998201],
           [  0.        ,   0.        ,  -9.25451794],
           [  0.        ,   0.        ,   0.        ],
           [  0.        ,   0.        ,   0.        ]])
    
    The update is equivalent, but faster than the following.

    >>> a_up = a + np.outer(u, v)
    >>> q_direct, r_direct = linalg.qr(a_up)

    Check that we have equivalent results:

    >>> np.allclose(np.dot(q_up, r_up), a_up)
    True

    And the updated Q is still unitary:

    >>> np.allclose(np.dot(q_up.T, q_up), np.eye(5))
    True

    Updating economic (reduced, thin) decompositions is also possible:
    >>> qe, re = linalg.qr(a, mode='economic')
    >>> qe_up, re_up = linalg.qr_update(qe, re, u, v, False)
    >>> qe_up
    array([[ 0.54073807,  0.18645997,  0.81707661],
           [ 0.21629523, -0.63257324,  0.06567893],
           [ 0.05407381,  0.64757787, -0.12781284],
           [ 0.48666426, -0.30466718, -0.27487277],
           [ 0.64888568,  0.23001   , -0.4859845 ]])
    >>> re_up
    array([[ 18.49324201,  24.11691794, -44.98940746],
           [  0.        ,  31.95894662, -27.40998201],
           [  0.        ,   0.        ,  -9.25451794]])
    >>> np.allclose(np.dot(qe_up, re_up), a_up)
    True
    >>> np.allclose(np.dot(qe_up.T, qe_up), np.eye(3))
    True

    Similarly to the above, perform a rank 2 update.
    >>> u2 = np.array([[ 7., -1,],
                       [-2.,  4.],
                       [ 4.,  2.],
                       [ 3., -6.],
                       [ 5.,  3.]])
    >>> v2 = np.array([[ 1., 2.],
                       [ 3., 4.],
                       [-5., 2]])
    >>> q_up2, r_up2 = linalg.qr_update(q, r, u, v, False)
    >>> q_up2
    array([[-0.33626508, -0.03477253,  0.61956287, -0.64352987, -0.29618884],
           [-0.50439762,  0.58319694, -0.43010077, -0.33395279,  0.33008064],
           [-0.21016568, -0.63123106,  0.0582249 , -0.13675572,  0.73163206],
           [ 0.12609941,  0.49694436,  0.64590024,  0.31191919,  0.47187344],
           [-0.75659643, -0.11517748,  0.10284903,  0.5986227 , -0.21299983]])
    >>> r_up2
    array([[-23.79075451, -41.1084062 ,  24.71548348],
           [  0.        , -33.83931057,  11.02226551],
           [  0.        ,   0.        , -48.91476811],
           [ -0.        ,   0.        ,   0.        ],
           [  0.        ,   0.        ,   0.        ]])

    This update is also a valid qr decomposition of ``A + U V**T``.

    >>> a_up2 = a + np.dot(u2, v2.T)
    >>> np.allclose(a_up2, np.dot(q_up2, r_up2))
    True
    >>> np.allclose(np.dot(q_up2.T, q_up2), np.eye(5))
    True

    """
    cdef cnp.ndarray q1, r1, u1, v1, qTu, s
    cdef int uv_flags = cnp.NPY_BEHAVED_NS | cnp.NPY_ELEMENTSTRIDES
    cdef int typecode, p, m, n, info
    cdef int qs[2]
    cdef int rs[2]
    cdef void* qTuvoid
    cdef int qTus[2]
    cdef int us[2]
    cdef int vs[2]
    cdef int ss[2]
    cdef bint economic, qisF = False
    cdef cnp.npy_intp ndim, len

    # Rather than overspecify our order requirements on Q and R, let anything
    # through then adjust.
    q1, r1, typecode, m, n, economic = validate_qr(Q, R, overwrite_qruv, NPY_ANYORDER,
            overwrite_qruv, NPY_ANYORDER, check_finite)

    if not overwrite_qruv:
        uv_flags |= cnp.NPY_ENSURECOPY
    u1 = PyArray_CheckFromAny(u, NULL, 0, 0, uv_flags, NULL)
    v1 = PyArray_CheckFromAny(v, NULL, 0, 0, uv_flags, NULL)

    if cnp.PyArray_TYPE(u1) != typecode or cnp.PyArray_TYPE(v1) != typecode:
        raise ValueError('u and v must have the same type as Q and R')

    if u1.shape[0] != m: 
        raise ValueError('u.shape[0] must equal Q.shape[0]')

    if v1.shape[0] != n:
        raise ValueError('v.shape[0] must equal R.shape[1]')

    if u1.ndim > 2 or v1.ndim > 2:
        raise ValueError('u and v can be no more than 2d')

    if u1.ndim != v1.ndim:
        raise ValueError('u and v must have the same number of dimensions')
    
    if u1.ndim == 2 and u1.shape[1] != v1.shape[1]:
        raise ValueError('Second dimension of u and v must be the same')

    if u1.ndim == 1:
        p = 1
    else:
        p = u1.shape[1]

    # limit p to at most max(n, m)
    if p > n or p > m:
        raise ValueError('Update rank larger than np.dot(Q, R).')

    u1 = validate_array(u1, check_finite)
    v1 = validate_array(v1, check_finite)

    if economic:
        ndim = 1
        len = 2*n
        s = cnp.PyArray_ZEROS(ndim, &len, typecode, 1)
        if not cnp.PyArray_ISONESEGMENT(q1):
            q1 = PyArray_FromArraySafe(q1, NULL, cnp.NPY_F_CONTIGUOUS)
            qisF = True
        elif cnp.PyArray_CHKFLAGS(q1, cnp.NPY_F_CONTIGUOUS):
            qisF = True
        else:
            qisF = False
        if p == 1:
            if typecode == cnp.NPY_FLOAT:
                thin_qr_rank_1_update(m, n,
                    <float*>extract(q1, qs), qs, qisF,
                    <float*>extract(r1, rs), rs,
                    <float*>extract(u1, us), us,
                    <float*>extract(v1, vs), vs,
                    <float*>extract(s, ss), ss)
            elif typecode == cnp.NPY_DOUBLE:
                thin_qr_rank_1_update(m, n,
                    <double*>extract(q1, qs), qs, qisF,
                    <double*>extract(r1, rs), rs,
                    <double*>extract(u1, us), us,
                    <double*>extract(v1, vs), vs,
                    <double*>extract(s, ss), ss)
            elif typecode == cnp.NPY_CFLOAT:
                thin_qr_rank_1_update(m, n,
                    <float_complex*>extract(q1, qs), qs, qisF,
                    <float_complex*>extract(r1, rs), rs,
                    <float_complex*>extract(u1, us), us,
                    <float_complex*>extract(v1, vs), vs,
                    <float_complex*>extract(s, ss), ss)
            else: # cnp.NPY_CDOUBLE
                thin_qr_rank_1_update(m, n,
                    <double_complex*>extract(q1, qs), qs, qisF,
                    <double_complex*>extract(r1, rs), rs,
                    <double_complex*>extract(u1, us), us,
                    <double_complex*>extract(v1, vs), vs,
                    <double_complex*>extract(s, ss), ss)
        else:
            if typecode == cnp.NPY_FLOAT:
                thin_qr_rank_p_update(m, n, p,
                    <float*>extract(q1, qs), qs, qisF,
                    <float*>extract(r1, rs), rs,
                    <float*>extract(u1, us), us,
                    <float*>extract(v1, vs), vs,
                    <float*>extract(s, ss), ss)
            elif typecode == cnp.NPY_DOUBLE:
                thin_qr_rank_p_update(m, n, p,
                    <double*>extract(q1, qs), qs, qisF,
                    <double*>extract(r1, rs), rs,
                    <double*>extract(u1, us), us,
                    <double*>extract(v1, vs), vs,
                    <double*>extract(s, ss), ss)
            elif typecode == cnp.NPY_CFLOAT:
                thin_qr_rank_p_update(m, n, p,
                    <float_complex*>extract(q1, qs), qs, qisF,
                    <float_complex*>extract(r1, rs), rs,
                    <float_complex*>extract(u1, us), us,
                    <float_complex*>extract(v1, vs), vs,
                    <float_complex*>extract(s, ss), ss)
            else: # cnp.NPY_CDOUBLE
                thin_qr_rank_p_update(m, n, p,
                    <double_complex*>extract(q1, qs), qs, qisF,
                    <double_complex*>extract(r1, rs), rs,
                    <double_complex*>extract(u1, us), us,
                    <double_complex*>extract(v1, vs), vs,
                    <double_complex*>extract(s, ss), ss)
    else:
        qTu = cnp.PyArray_ZEROS(u1.ndim, u1.shape, typecode, 1)
        qTuvoid = extract(qTu, qTus)
        if p == 1:
            if not cnp.PyArray_ISONESEGMENT(q1):
                q1 = PyArray_FromArraySafe(q1, NULL, cnp.NPY_F_CONTIGUOUS)
            form_qTu(q1, u1, qTuvoid, qTus, 0)
            if typecode == cnp.NPY_FLOAT:
                qr_rank_1_update(m, n,
                    <float*>extract(q1, qs), qs,
                    <float*>extract(r1, rs), rs,
                    <float*>qTuvoid, qTus,
                    <float*>extract(v1, vs), vs)
            elif typecode == cnp.NPY_DOUBLE:
                qr_rank_1_update(m, n,
                    <double*>extract(q1, qs), qs,
                    <double*>extract(r1, rs), rs,
                    <double*>qTuvoid, qTus,
                    <double*>extract(v1, vs), vs)
            elif typecode == cnp.NPY_CFLOAT:
                qr_rank_1_update(m, n,
                    <float_complex*>extract(q1, qs), qs,
                    <float_complex*>extract(r1, rs), rs,
                    <float_complex*>qTuvoid, qTus,
                    <float_complex*>extract(v1, vs), vs)
            else: # cnp.NPY_CDOUBLE
                qr_rank_1_update(m, n,
                    <double_complex*>extract(q1, qs), qs,
                    <double_complex*>extract(r1, rs), rs,
                    <double_complex*>qTuvoid, qTus,
                    <double_complex*>extract(v1, vs), vs)
        else:
            if not cnp.PyArray_CHKFLAGS(q1, cnp.NPY_F_CONTIGUOUS):
                q1 = PyArray_FromArraySafe(q1, NULL, cnp.NPY_F_CONTIGUOUS)
            if not cnp.PyArray_CHKFLAGS(r1, cnp.NPY_F_CONTIGUOUS):
                r1 = PyArray_FromArraySafe(r1, NULL, cnp.NPY_F_CONTIGUOUS)
            if not cnp.PyArray_ISONESEGMENT(u1):
                u1 = PyArray_FromArraySafe(u1, NULL, cnp.NPY_F_CONTIGUOUS)
            # v.T must be F contiguous --> v must be C contiguous
            if not cnp.PyArray_CHKFLAGS(v1, cnp.NPY_C_CONTIGUOUS):
                v1 = PyArray_FromArraySafe(v1, NULL, cnp.NPY_C_CONTIGUOUS)
            # can we do better than this python call to get the strides right?
            v1 = v1.T
            form_qTu(q1, u1, qTuvoid, qTus, 0)
            if typecode == cnp.NPY_FLOAT:
                info = qr_rank_p_update(m, n, p,
                    <float*>extract(q1, qs), qs,
                    <float*>extract(r1, rs), rs,
                    <float*>qTuvoid, qTus,
                    <float*>extract(v1, vs), vs)
            elif typecode == cnp.NPY_DOUBLE:
                info = qr_rank_p_update(m, n, p,
                    <double*>extract(q1, qs), qs,
                    <double*>extract(r1, rs), rs,
                    <double*>qTuvoid, qTus,
                    <double*>extract(v1, vs), vs)
            elif typecode == cnp.NPY_CFLOAT:
                info = qr_rank_p_update(m, n, p,
                    <float_complex*>extract(q1, qs), qs,
                    <float_complex*>extract(r1, rs), rs,
                    <float_complex*>qTuvoid, qTus,
                    <float_complex*>extract(v1, vs), vs)
            else: # cnp.NPY_CDOUBLE
                info = qr_rank_p_update(m, n, p,
                    <double_complex*>extract(q1, qs), qs,
                    <double_complex*>extract(r1, rs), rs,
                    <double_complex*>qTuvoid, qTus,
                    <double_complex*>extract(v1, vs), vs)
            if info != 0:
                if info > 0: 
                    raise ValueError('The {0}th argument to ?geqrf was'
                            'invalid'.format(info))
                elif info < 0:
                    raise ValueError('The {0}th argument to ?ormqr/?unmqr was'
                            'invalid'.format(abs(info)))
                elif info == MEMORY_ERROR:
                    raise MemoryError('malloc failed')
    return q1, r1

cnp.import_array()

