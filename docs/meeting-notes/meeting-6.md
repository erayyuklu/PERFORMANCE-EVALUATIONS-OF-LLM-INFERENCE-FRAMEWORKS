# Meeting Notes - Week 6

## Summary

- Discussed adding TurboQuant quantization framework to the experiments and conducting capacity limits testing for both concurrent users and model sizes on the L4 GPU.
- Refined the evaluation methodology for reasoning versus non-reasoning models.

## Discussion Points & Research Items

- **TurboQuant integration:** Research TurboQuant and incorporate it into the experiments to evaluate its potential advantages in performance.
- **L4 Capacity Limits (Concurrent Users):** Investigate the maximum number of concurrent users that can be served on an L4 GPU, testing across different quantization levels and reasoning vs. non-reasoning configurations, and compare the results with the results of TurboQuant.
- **L4 Capacity Limits (Model Size):** Determine the largest possible model that can be successfully run on a single L4 GPU using various quantization techniques, and compare the results with the results of TurboQuant.
- **Reasoning Evaluation Methodology:** Noted that previous tests comparing reasoning vs. non-reasoning used different model families. We need to standardize this by using the exact same model, toggling reasoning on and off to ensure a fair comparison.

## Next Steps

- [ ] **TurboQuant Research & Testing:** Research TurboQuant and add it to the testing suite to document its impact.
- [ ] **Max User Capacity Tests:** Run experiments to find the maximum concurrent user count on an L4 GPU under different quantizations and reasoning settings.
- [ ] **Max Model Size Tests:** Identify and test the maximum theoretical model sizes that can fit on an L4 GPU under various quantization levels.
- [ ] **Standardized Reasoning Tests:** Rerun reasoning vs. non-reasoning performance tests using the exact same model (with reasoning turned on and off) rather than comparing completely different models.
