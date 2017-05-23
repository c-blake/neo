# Copyright 2017 UniCredit S.p.A.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import nimcuda/[cuda_runtime_api, driver_types, cublas_api, cublas_v2, nimcuda]
import ../dense

type
  CudaVector*[A] = object
    N*: int
    data*: ref[ptr A]
  CudaMatrix*[A] = object
    M*, N*: int
    data*: ref[ptr A]

template fp[A](c: CudaVector[A] or CudaMatrix[A]): ptr float32 = c.data[]

proc cudaMalloc[A](size: int): ptr A =
  let s = size * sizeof(A)
  check cudaMalloc(cast[ptr pointer](addr result), s)

proc freeDeviceMemory[A: SomeReal](p: ref[ptr A]) =
  check cudaFree(p[])

# Copying between host and device

proc gpu*[A: SomeReal](v: Vector[A]): CudaVector[A] =
  new result.data, freeDeviceMemory
  result.data[] = cudaMalloc[A](v.len)
  result.N = v.len
  check cublasSetVector(v.len, sizeof(A), v.fp, 1, result.fp, 1)

proc gpu*[A: SomeReal](m: Matrix[A]): CudaMatrix[A] =
  if m.order == rowMajor: quit("wrong order")
  new result.data, freeDeviceMemory
  result.data[] = cudaMalloc[A](m.M * m.N)
  result.M = m.M
  result.N = m.N
  check cublasSetMatrix(m.M, m.N, sizeof(A), m.fp, m.M, result.fp, m.M)

proc cpu*[A: SomeReal](v: CudaVector[A]): Vector[A] =
  result = newSeq[A](v.N)
  check cublasGetVector(v.N, sizeof(A), v.fp, 1, result.fp, 1)

proc cpu*[A: SomeReal](m: CudaMatrix[A]): Matrix[A] =
  new result
  result.order = colMajor
  result.data = newSeq[A](m.M * m.N)
  result.M = m.M
  result.N = m.N
  check cublasGetMatrix(m.M, m.N, sizeof(A), m.fp, m.M, result.fp, m.M)

# Printing

proc `$`*[A](v: CudaVector[A]): string = $(v.cpu())

proc `$`*[A](m: CudaMatrix[A]): string = $(m.cpu())

# Equality

proc `==`*[A](m, n: CudaVector[A]): bool =
  m.cpu() == n.cpu()

proc `==`*[A](m, n: CudaMatrix[A]): bool =
  m.cpu() == n.cpu()

# BLAS overloads

var defaultHandle: cublasHandle_t
check cublasCreate_v2(addr defaultHandle)

proc cublasScal(handle: cublasHandle_t, n: int, alpha: float32, x: ptr float32): cublasStatus_t =
  cublasSscal(handle, n.cint, unsafeAddr(alpha), x, 1)

proc cublasScal(handle: cublasHandle_t, n: int, alpha: float64, x: ptr float64): cublasStatus_t =
  cublasDscal(handle, n.cint, unsafeAddr(alpha), x, 1)

proc cublasAxpy(handle: cublasHandle_t, n: int, alpha: float32, x, y: ptr float32): cublasStatus_t =
  cublasSaxpy(handle, n.cint, unsafeAddr(alpha), x, 1, y, 1)

proc cublasAxpy(handle: cublasHandle_t, n: int, alpha: float64, x, y: ptr float64): cublasStatus_t =
  cublasDaxpy(handle, n.cint, unsafeAddr(alpha), x, 1, y, 1)

proc cublasGemv(handle: cublasHandle_t, trans: cublasTransposeType,
  m, n: int, alpha: float32, A: ptr float32, lda: int, x: ptr float32, incx: int,
  beta: float32, y: ptr float32, incy: int): cublasStatus_t =
  cublasSgemv(handle, trans, m, n, unsafeAddr(alpha), A, lda, x, incx, unsafeAddr(beta), y, incy)

proc cublasGemv(handle: cublasHandle_t, trans: cublasTransposeType,
  m, n: int, alpha: float64, A: ptr float64, lda: int, x: ptr float64, incx: int,
  beta: float64, y: ptr float64, incy: int): cublasStatus_t =
  cublasDgemv(handle, trans, m, n, unsafeAddr(alpha), A, lda, x, incx, unsafeAddr(beta), y, incy)

proc cublasGemm(handle: cublasHandle_t, transa, transb: cublasTransposeType,
  m, n, k: int, alpha: float32, A: ptr float32, lda: int, B: ptr float32,
  ldb: int, beta: float32, C: ptr float32, ldc: int): cublasStatus_t =
  cublasSgemm(handle, transa, transb, m, n, k, unsafeAddr(alpha), A, lda, B, ldb, unsafeAddr(beta), C, ldc)

proc cublasGemm(handle: cublasHandle_t, transa, transb: cublasTransposeType,
  m, n, k: int, alpha: float64, A: ptr float64, lda: int, B: ptr float64,
  ldb: int, beta: float64, C: ptr float64, ldc: int): cublasStatus_t =
  cublasDgemm(handle, transa, transb, m, n, k, unsafeAddr(alpha), A, lda, B, ldb, unsafeAddr(beta), C, ldc)

# BLAS level 1 operations

template init[A](v: CudaVector[A], n: int) =
  new v.data, freeDeviceMemory
  v.data[] = cudaMalloc[A](n)
  v.N = n

template init[A](v: CudaMatrix[A], m, n: int) =
  new v.data, freeDeviceMemory
  v.data[] = cudaMalloc[A](m * n)
  v.M = m
  v.N = n

proc `*=`*[A: SomeReal](v: var CudaVector[A], k: A) {. inline .} =
  check cublasScal(defaultHandle, v.N, k, v.fp)

proc `*`*[A: SomeReal](v: CudaVector[A], k: A): CudaVector[A]  {. inline .} =
  init(result, v.N)
  check cublasCopy(defaultHandle, N, v.fp, 1, result.fp, 1)
  check cublasScal(defaultHandle, N, k, result.fp)

proc `+=`*[A: SomeReal](v: var CudaVector[A], w: CudaVector[A]) {. inline .} =
  assert(v.N == w.N)
  check cublasAxpy(defaultHandle, v.N, 1, w.fp, v.fp)

proc `+`*[A: SomeReal](v, w: CudaVector[A]): CudaVector[A] {. inline .} =
  assert(v.N == w.N)
  init(result, v.N)
  check cublasCopy(defaultHandle, N, v.fp, 1, result.fp, 1)
  check cublasAxpy(defaultHandle, N, 1, w.fp, result.fp)

proc `-=`*[A: SomeReal](v: var CudaVector[A], w: CudaVector[A]) {. inline .} =
  assert(v.N == w.N)
  check cublasAxpy(defaultHandle, v.N, -1, w.fp, v.fp)

proc `-`*[A: SomeReal](v, w: CudaVector[A]): CudaVector[A] {. inline .} =
  assert(v.N == w.N)
  init(result, v.N)
  check cublasCopy(defaultHandle, N, v.fp, 1, result.fp, 1)
  check cublasAxpy(defaultHandle, N, -1, w.fp, result.fp)

proc `*`*[A: SomeReal](v, w: CudaVector[A]): A {. inline .} =
  assert(v.N == w.N)
  check cublasDot(defaultHandle, v.N, v.fp, 1, w.fp, 1, addr(result))

proc l_2*[A: SomeReal](v: CudaVector[A]): A {. inline .} =
  check cublasNrm2(defaultHandle, v.N, v.fp, 1, addr(result))

proc l_1*[A: SomeReal](v: CudaVector[A]): A {. inline .} =
  check cublasAsum(defaultHandle, v.N, v.fp, 1, addr(result))

proc `*=`*[A: SomeReal](m: var CudaMatrix[A], k: A) {. inline .} =
  check cublasScal(defaultHandle, m.M * m.N, k, m.fp)

proc `*`*[A: SomeReal](m: CudaMatrix[A], k: A): CudaMatrix[A]  {. inline .} =
  init(result, m.M, m.N)
  check cublasCopy(defaultHandle, m.M * m.N, m.fp, 1, result.fp, 1)
  check cublasScal(defaultHandle, m.M * m.N, k, result.fp)

template `*`*[A: SomeReal](k: A, v: CudaVector[A] or CudaMatrix[A]): auto =
  v * k

template `/`*[A: SomeReal](v: CudaVector[A] or CudaMatrix[A], k: A): auto =
  v * (1 / k)

template `/=`*[A: SomeReal](v: var CudaVector[A] or var CudaMatrix[A], k: A) =
  v *= (1 / k)

proc `+=`*[A: SomeReal](a: var CudaMatrix[A], b: CudaMatrix[A]) {. inline .} =
  assert a.M == b.M and a.N == a.N
  check cublasAxpy(defaultHandle, a.M * a.N, 1, b.fp, a.fp)

proc `+`*[A: SomeReal](a, b: CudaMatrix[A]): CudaMatrix[A]  {. inline .} =
  assert a.M == b.M and a.N == a.N
  init(result, a.M, a.N)
  check cublasCopy(defaultHandle, a.M * a.N, a.fp, 1, result.fp, 1)
  check cublasAxpy(defaultHandle, a.M * a.N, 1, b.fp, result.fp)

proc `-=`*[A: SomeReal](a: var CudaMatrix[A], b: CudaMatrix[A]) {. inline .} =
  assert a.M == b.M and a.N == a.N
  check cublasAxpy(defaultHandle, a.M * a.N, -1, b.fp, a.fp)

proc `-`*[A: SomeReal](a, b: CudaMatrix[A]): CudaMatrix[A]  {. inline .} =
  assert a.M == b.M and a.N == a.N
  init(result, a.M, a.N)
  check cublasCopy(defaultHandle, a.M * a.N, a.fp, 1, result.fp, 1)
  check cublasAxpy(defaultHandle, a.M * a.N, -1, b.fp, result.fp)

proc l_2*[A: SomeReal](m: CudaMatrix[A]): A {. inline .} =
  check cublasNrm2(defaultHandle, m.M * m.N, m.fp, 1, addr(result))

proc l_1*[A: SomeReal](m: CudaMatrix[A]): A {. inline .} =
  check cublasAsum(defaultHandle, m.M * m.N, m.fp, 1, addr(result))

# BLAS level 2 operations

proc `*`*[A: SomeReal](a: CudaMatrix[A], v: CudaVector[A]): CudaVector[A]  {. inline .} =
  assert(a.N == v.N)
  init(result, a.M)
  check cublasGemv(defaultHandle, cuNoTranspose, a.M, a.N, 1, a.fp, a.M, v.fp, 1, 0, result.fp, 1)

# BLAS level 3 operations

proc `*`*[A: SomeReal](a, b: CudaMatrix[A]): CudaMatrix[A] {. inline .} =
  assert a.N == b.M
  init(result, a.M, b.N)
  check cublasGemm(handle, cuNoTranspose, cuNoTranspose, a.M, b.N, a.N, 1,
    a.fp, a.M, b.fp, a.N, 0, result.fp, a.M)

# Comparison

template compareApprox(a, b: CudaVector or CudaMatrix): bool =
  const epsilon = 0.000001
  let
    aNorm = l_1(a)
    bNorm = l_1(b)
    dNorm = l_1(a - b)
  return (dNorm / (aNorm + bNorm)) < epsilon

proc `=~`*[A: SomeReal](v, w: CudaVector[A]): bool = compareApprox(v, w)

proc `=~`*[A: SomeReal](v, w: CudaMatrix[A]): bool = compareApprox(v, w)

template `!=~`*(a, b: CudaVector or CudaMatrix): bool = not (a =~ b)