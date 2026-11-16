# Portfolio checklist

Run through this before you publish a project.

## Correctness
- [ ] Every number in the README came from a real run of the code in the repository.
- [ ] Totals **reconcile** against an independent source (a control total, not the same query).
- [ ] The **grain** of every table is stated, and no measure is summed at the wrong grain.
- [ ] Edge cases are handled and tested: empty input, missing values, duplicates, a cycle in the data.

## Testing
- [ ] The project has **self-checks** with an expected value, an actual value and a pass flag.
- [ ] A check **can fail**: you have broken the data on purpose and seen it fail.
- [ ] The tests run **automatically** (CI), on more than one PostgreSQL version if you can.
- [ ] Running the code twice gives the same result (**idempotent**) and leaves no mess behind.

## Safety
- [ ] Experiments run inside a transaction you roll back, or in a throw-away schema.
- [ ] No credentials, personal data or real customer records anywhere in the repository (history included).
- [ ] The data is synthetic or you have the right to publish it, and the README says which.

## Documentation
- [ ] The README answers, in order: the problem, what it demonstrates, the design, how to run it, the results, how it is tested, the limitations, the next steps.
- [ ] Someone can run it in five minutes by following the README.
- [ ] A **Limitations** section exists and is honest.
- [ ] Tables and columns are documented (a `COMMENT`, or a data dictionary generated from the catalog).

## Presentation
- [ ] The repository has a clear name, a one-line description and topics (`postgresql`, `sql`, and so on).
- [ ] A licence file is present.
- [ ] The CI badge is green.
- [ ] Screenshots or output tables are real, current and readable.

## Honesty
- [ ] Your CV or LinkedIn describes **only what you built**, in specific terms.
- [ ] You can explain every line of the SQL and every design decision, because you will be asked.
- [ ] You name the tools you used and not the ones you did not.
