# Development Rules for SMAK

## Testing Requirements

### **Don't break things that are working**
- Run the full regression test suite before starting work (establish baseline)
- Run tests after making changes
- **Don't introduce new test failures** - your changes should not break tests that were passing
- Fix one thing at a time - you don't need to fix all pre-existing failures before committing
- Document the baseline test state in `reports/` directory

### Running Tests
```bash
# Run full regression suite
cd test && ./run-regression

# Run tests in parallel (faster)
cd test && ./run-regression -j 4

# Or use the test-before-push script
./test/test-before-push

# Test committed changes before pushing (tests in a clean clone)
# Useful for verifying that your commits work correctly in isolation
cd test && ./run-regression -clone local
```

## Development Workflow

1. **Read Before Modifying**
   - Always read existing code before proposing changes
   - Understand the current implementation and patterns

2. **Test-Driven Development**
   - Establish baseline: run tests before starting work
   - Make your changes
   - Run tests after making changes
   - Ensure no new failures were introduced

3. **Keep Changes Focused**
   - Make only the requested changes
   - Avoid over-engineering or unnecessary refactoring
   - Don't add features beyond what was asked

## Git Practices

1. **Branching**
   - Work on feature branches (format: `claude/<description>-<session-id>`)
   - Never push directly to main/master

2. **Committing**
   - Write clear, descriptive commit messages
   - Ensure no new test failures were introduced
   - Commit logical units of work

3. **Pushing**
   - Use `git push -u origin <branch-name>`
   - Retry network failures up to 4 times with exponential backoff

## Code Quality

1. **Security**
   - Check for vulnerabilities (XSS, SQL injection, command injection, etc.)
   - Validate input at system boundaries
   - Don't introduce new security issues

2. **Simplicity**
   - Keep solutions simple and direct
   - Delete unused code completely
   - Avoid backwards-compatibility hacks

3. **Documentation**
   - Only add comments where logic isn't self-evident
   - Don't add docstrings to code you didn't change

## When in Doubt

- Ask for clarification rather than making assumptions
- Prioritize code that works over code that's "clever"
- Simple and correct beats complex and fragile
