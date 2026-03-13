# System Architecture

This directory contains the foundational design documents, principles, and architectural decisions that govern the development of ZyncBase.

---

## 🏗️ [Core Principles](./core-principles.md)
The high-level philosophy and "North Star" goals for the project. These nine principles guide every technical trade-off and feature design, focusing on real-time performance, self-hosting, and developer experience.

## 📜 [Architecture Decision Records (ADRs)](./adrs.md)
A chronological log of significant architectural decisions. Each ADR documents the context, the decision made, the rationale behind it, and the consequences.

**Key Decision Areas:**
- **Technology Stack**: Choice of Zig, uWebSockets, and SQLite.
- **Engine Design**: Multi-threading, lock-free caching, and storage optimization.
- **API & Protocol**: MessagePack wire format, Prisma-inspired queries, and optimistic writes.
- **Security**: Declarative authorization and server-side validation.

## 🔍 Architectural Deep Dives
Detailed technical specifications and implementation strategies for core system components:

- **[Threading Model](./threading-model.md)**: Separation of read/write concerns and utilization of multi-core hardware.
- **[Storage Layer](./storage-layer.md)**: Optimizing SQLite for high-concurrency real-time workloads using WAL mode.
- **[Lock-Free Cache](./lock-free-cache.md)**: Implementation details of the atomic reference-counted in-memory cache.

---

## 📚 See Also
- **[Research](./research.md)**: Technical validation, academic citations, and performance benchmarks that inform our designs.
- **[API Design](../api-design/README.md)**: Specifications for public-facing interfaces and communication protocols.
