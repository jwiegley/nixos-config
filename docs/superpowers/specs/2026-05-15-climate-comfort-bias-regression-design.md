# Climate Comfort — bias regression upgrade

**Status:** Draft 2026-05-15 (for later implementation)
**Author:** John Wiegley (with Claude design assistance)
**Depends on:** `2026-05-14-climate-comfort-design.md`

## Motivation

The current bias system stores a single °F offset per `(zone, mode, hour)` bucket and updates each bucket via EMA on manual overrides. This captures *time-of-day preferences* well but cannot encode *conditional* preferences — e.g., "I want 84 °F at 14:00 when it's 100 °F outside, but only 82 °F at 14:00 when it's 80 °F outside." Such a curve gets averaged into a single number per bucket.

This spec replaces each bucket's scalar with a small linear model fit by recursive least squares (RLS), so the system can learn `setpoint_bias = f(features)` per zone.

This is not urgent. The current EMA system should run for at least 2-4 weeks first to determine whether bucket jitter actually warrants the additional complexity.

## Trigger to implement

Implement this spec only if, after ≥ 4 weeks of EMA operation, any of the following is true:

- A bucket's recent samples (last 7 days) show variance > 1.5 °F that correlates with `outdoor_7d_mean` or `current_temperature`.
- User reports the system "feels right in the morning but wrong in the afternoon" or vice versa under similar mode/hour conditions.
- Distinct sub-clusters appear in a single bucket's setpoint history (visible as a bimodal distribution in Grafana).

If none of those hold, the per-hour-bucket EMA is sufficient and this spec stays on the shelf.

## Design

### Model

Per `(zone, mode)` pair — *not* per hour — fit:

```
bias = β₀ + β₁ · outdoor_7d_mean + β₂ · current_temperature
       + β₃ · sin(2π · hour / 24) + β₄ · cos(2π · hour / 24)
```

The cyclic hour encoding (β₃, β₄) replaces the 24 separate hour buckets with a smooth sinusoidal hour-of-day curve, which:
- Reduces total state from 6 × 3 × 24 = 432 buckets to 6 × 3 = 18 models (better data efficiency).
- Forces smoothness across adjacent hours, preventing the "14:00 says 82, 15:00 says 86" jitter that independent buckets allow.
- Costs one more harmonic to add if a single sinusoid proves too smooth (β₅ · sin(4π·h/24) + β₆ · cos(4π·h/24)).

### Recursive least squares update

On each detected manual override (current deadband + step-cap logic preserved):

```
x = [1, T_out, T_in, sin(2π h/24), cos(2π h/24)]    # feature vector
P_prev = model.P                                     # 5×5 covariance matrix
β_prev = model.beta                                  # 5-vector

target  = lastWrittenSetpoint + delta                # observed user-preferred setpoint
y       = target - formula_setpoint                  # the residual the bias should explain

k       = P_prev · x / (1 + xᵀ · P_prev · x)         # Kalman gain (scalar denom)
β_new   = β_prev + k · (y - xᵀ · β_prev)
P_new   = P_prev - k · xᵀ · P_prev
```

This is exact least squares — no learning-rate to tune. Forgetting factor λ ∈ (0.95, 0.99) can be added to weight recent samples higher; equivalent to the EMA half-life concept.

### Storage shape

```javascript
flow.bias = {
  "climate.upstairs|cool":  { beta: [β₀..β₄], P: [[..]], n: 73, last_ts: 1778... },
  "climate.upstairs|heat":  { ... },
  "climate.upstairs|heat_cool": { ... },
  "climate.living_room|cool": { ... },
  ...
}
```

18 entries, each ~30 numbers (5 β + 25 covariance + scalars). ~540 numbers total — tiny.

### Cold-start

A regression with n < 5 samples produces unstable predictions. Until each model has accumulated ≥ 10 samples, fall back to the per-hour-bucket EMA value (kept in parallel during the transition).

```javascript
const biasValue = model.n >= 10
    ? dot(features, model.beta)
    : (bias_legacy[`${zone}|${mode}|${hour}`] || 0);
```

The legacy EMA buckets keep updating in shadow during the transition so that no learned state is lost if the regression is rolled back.

### Migration

1. Deploy spec without removing legacy EMA. Both systems update in parallel.
2. Run for ≥ 2 weeks. Confirm models accumulate samples and produce sensible predictions across the parameter space (Grafana panel: predicted bias vs `(T_out, hour)` heatmap).
3. Flip the `MODEL_AUTHORITATIVE` flag to true. Compute function reads from regression, falls back to EMA only when n < 10.
4. After another 4 weeks of stable operation, delete legacy EMA bucket update code.

### Safety bounds

Predicted bias is clamped to the same ±8 °F total as the current system. RLS itself is unbounded; the clamp prevents a poorly-conditioned model from producing absurd setpoints in unusual conditions (e.g., extrapolating to outdoor temps never seen before).

### Observability

Three new Grafana panels driven by `msg_events`:

| Panel | Query | Shows |
|---|---|---|
| Bias prediction heatmap | sample model output across (T_out, hour) grid every cycle, log to `msg_events` | the learned 2-D bias surface per zone |
| Sample count per model | latest `n` from each of 18 models | which models are still in cold-start |
| Prediction vs override scatter | join manual-override events to model predictions at that time | model accuracy; large residuals → re-tune features |

## Non-goals

- Multi-day patterns (weekend vs weekday) — would require adding day-of-week features; deferred until the simple model is validated.
- Humidity, sun position, occupancy as features — also deferred.
- Per-zone slope of `outdoor_7d_mean` — the regression captures this automatically via β₁, but if some zones need a quadratic outdoor term and others don't, that's a per-zone feature set complication left for future work.
- Replacing the ASHRAE 55 anchor itself with a regression — the anchor is intentionally a hard-coded physical comfort model; the regression learns the *residual* on top, not the whole setpoint.

## Risks

- **Overfitting in low-data regimes**: covered by cold-start fallback and ±8 °F clamp.
- **Extrapolation outside training range**: e.g., model trained at 70-90 °F outdoor will produce nonsense at 110 °F. Mitigated by clamp. Long term, switch to a kernel-regression or gradient-boosted-tree per zone (an order more complex; not in scope here).
- **Bias drift after seasonal transition**: when first switching from `heat` to `heat_cool` to `cool` modes, the new mode's model has stale data from a year ago. Use a higher forgetting factor (λ = 0.95) on the first 50 samples after a mode change, then settle to 0.99.

## Acceptance test

1. Deploy alongside existing EMA. Verify both update on manual overrides.
2. After 10 samples in one zone's `cool` model, log a Grafana panel showing predicted bias across a `(T_out, hour)` grid. Manually inspect for plausibility (no NaNs, no values outside ±8).
3. Compare predicted bias against next 10 manual overrides — RMS error should be < 1.5 °F by sample 50.
4. After 2 weeks, flip authoritative flag for one zone (e.g., `climate.upstairs`). Verify setpoint writes use the regression and zone behaves sensibly across 48 hours covering a 10 °F outdoor swing.
5. Roll the flag to remaining zones one at a time over 1-2 weeks each.

## Estimated effort

- Function code (RLS + cold-start fallback): ~60 lines per function node, replacing ~25 lines.
- Grafana panels: 3 new SQL queries, ~30 minutes.
- Validation: 4-6 weeks of passive observation, no engineering time.

Total active engineering work: half a day. Total wall-clock to deploy with confidence: ~2 months.
