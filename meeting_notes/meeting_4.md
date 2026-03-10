# Meeting Notes - Week 4

## Summary

- Reviewed the current test setup and went through the initial test results.

## Discussion Points & Research Items

- **Infrastructure:** Compared GCP versus Lightning AI setups; agreed that GCP remains the better option for now as it gives more free credits.
- **Scaling & Future Scope:**
  - Decided against scaling to multiple nodes for the time being.
  - Multi-modal models are currently out of scope and will not be used for now.
- **Testing Approach:** Discussed the vLLM benchmark tool versus Locust. Decided to stick with Locust for load testing but will use the vLLM benchmark tool as a reference point.

## Next Steps

- [ ] **Data & Prompts:** Transition to using standard prompt datasets (e.g, ShareGPT, Spec Bench, etc.) instead of custom-written prompts.
- [ ] **Load Testing:** Increase the load in upcoming tests.
- [ ] **Model Diversification:**
  - Test reasoning models, check if the current model supports reasoning.
  - Test with more specialized user profiles (e.g., coder user, text generation user, short question-answer user).
- [ ] **Optimization:** Try to achieve better performance results compared to the baseline default parameter setup.