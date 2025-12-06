# Specification Documents

This directory contains detailed specification documents for various features and systems in the debrid_drive_ex project.

## Purpose

Spec documents serve as:
- **Design Documentation**: Comprehensive design decisions and architecture
- **Implementation Guides**: Detailed behavior specifications for TDD
- **Reference Material**: Single source of truth for feature behavior
- **Communication Tool**: Clear specifications for team collaboration

## Directory Structure

```
specs/
├── README.md              # This file
├── DELETION_SPEC.md       # File and torrent deletion specification
└── [future specs...]
```

## How to Use This Directory

### Creating a New Spec

1. Create a new markdown file with descriptive name: `FEATURE_NAME_SPEC.md`
2. Follow the template structure below
3. Add entry to this README's "Specification Index"
4. Link related test files and implementation modules

### Spec Document Template

```markdown
# Feature Name Specification

## Overview
Brief description of the feature and its purpose.

## Architecture Principles
High-level design principles and constraints.

## Detailed Scenarios
### Scenario 1: [Name]
**Behavior**: What happens
**Implementation**: How it's implemented
**Tests**: Where it's tested

[... more scenarios ...]

## Database Schema
Required schema changes.

## API Contracts
gRPC/REST endpoints and their contracts.

## Error Handling
How errors are handled at each layer.

## Test Coverage
Links to test files and required test cases.

## Implementation Plan
Phased rollout strategy.

## Open Questions
Unresolved design decisions.
```

## Specification Index

### Core Features

#### [Deletion System](./DELETION_SPEC.md)
**Status**: 📝 Specified (Tests created, implementation pending)  
**Description**: Comprehensive deletion system for files, directories, hard links, and torrents with Real-Debrid API integration.  
**Key Concepts**:
- Immediate VFS deletions vs deferred API deletions
- Hard link cascade behavior
- Transactional guarantees
- Eventual consistency via sync engine

**Related Files**:
- Tests: `apps/vfs/test/vfs_deletion_test.exs`
- Tests: `apps/grpc_server/test/e2e/deletion_test.exs`
- Tests: `apps/sync_engine/test/sync_engine/deletion_test.exs`
- Implementation: (pending)

---

### Future Specs (Planned)

Add new specifications here as they are created:

- [ ] **HARD_LINK_SPEC.md** - Already implemented, needs documentation
- [ ] **SYNC_ENGINE_SPEC.md** - Torrent synchronization and reconciliation
- [ ] **STREAMING_SPEC.md** - Video streaming and caching behavior
- [ ] **PERMISSIONS_SPEC.md** - Access control and multi-user support
- [ ] **QUOTA_SPEC.md** - Storage quota management
- [ ] **CACHE_SPEC.md** - Disk cache and eviction policies
- [ ] **WEBHOOK_SPEC.md** - Real-Debrid webhook integration

---

## Specification Lifecycle

### 1. 📝 Specified
- Design documented
- Test files created
- Ready for implementation

### 2. 🚧 In Progress
- Implementation underway
- Tests failing → passing
- May require spec updates

### 3. ✅ Implemented
- All tests passing
- Code reviewed and merged
- Spec matches reality

### 4. 📚 Maintained
- Spec updated as feature evolves
- Historical context preserved
- Breaking changes documented

---

## Best Practices

### Writing Good Specs

1. **Start with User Scenarios**: Describe what the user does and expects
2. **Be Specific**: Include concrete examples with actual data
3. **Show Edge Cases**: Document error conditions and boundary cases
4. **Diagram When Helpful**: Use ASCII diagrams for complex flows
5. **Link to Code**: Reference specific files and line numbers where applicable
6. **Version Control**: Update specs as implementation evolves

### Keeping Specs Current

- Review specs during code review
- Update specs when behavior changes
- Archive obsolete specs (don't delete - they're historical context)
- Link PRs that implement specs

### Spec vs Comments

- **Specs**: High-level design, scenarios, architecture decisions
- **Comments**: Low-level implementation details, "why" explanations
- **Tests**: Executable specifications, actual behavior verification

---

## Contributing

When adding new features:

1. Write the spec first (TDD for design)
2. Review spec with team
3. Create test files based on spec
4. Implement to make tests pass
5. Update spec if implementation diverges
6. Mark spec as ✅ Implemented

When modifying existing features:

1. Update spec to reflect new behavior
2. Add/modify tests
3. Implement changes
4. Verify spec still matches implementation

---

## Questions?

If you're unsure about spec format or content:
- Look at existing specs for examples
- Prioritize clarity over formality
- Better to have an imperfect spec than no spec
- Specs can be iterated and improved

---

**Last Updated**: December 2, 2025
