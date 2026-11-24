# Gait Analysis Pipeline: Ankle-Foot Orthosis + Augmented-Reality Game

MATLAB pipeline for processing and analysing multi-sensor gait data from a single-case experimental design (SCED) study at Hospital Niño Jesús (Madrid). The study evaluates whether an augmented-reality game that rewards push-off, combined with a variable-stiffness ankle-foot orthosis (inGAIT-VSO), improves walking in children with cerebral palsy.

Developed by Ignacio Hernández Martínez during a research internship at the BioRobotics Group, Centre for Automation and Robotics (CAR, CSIC–UPM), extending the group's existing codebase.

> **No participant data is included in this repository.**

## What it does

A trial map links every recording to its trial, session and condition. The pipeline then runs in three stages:

1. **EMG processing.** Repairs recordings truncated by interrupted saves, applies zero-lag band-pass filtering, rectification and low-pass envelope extraction, detects the walking bout of each trial from the shank gyroscopes, and normalises each muscle to a reference level (99.5th percentile) pooled across all trials. A quality log scores every sensor in every trial, including EMG burst depth from the cycle-averaged envelope.
2. **Synchronisation and outcome extraction.** Reads the foot-sensor files (GaitUp Physilog) using the trial map, aligns them to the ROS clock by cross-correlating foot and shank gyroscope signals, and places all data streams on one time base: Delsys Trigno EMG and shank gyroscopes, the orthosis's forefoot insoles and ankle goniometer, the GaitUp foot sensors, and the AR game logs. It then extracts forefoot force and soleus, gastrocnemius and tibialis anterior EMG during push-off, within-step ratios that are insensitive to sensor refitting between sessions, cadence and stride time, and ankle range of motion.
3. **Statistics and figures.** Normalises every outcome to the participant's own baseline, produces intra- and inter-session results, and computes Non-overlap of All Pairs (NAP) and Tau-U with baseline-trend correction. It also reconstructs the AR game's difficulty rules and metrics from its logs, and estimates the torque applied by the orthosis from its setting and laboratory characterisation curves.

## Data quality and validation

- Nothing is excluded. Every trial is processed, missing data stay missing (never extrapolated), and sensor problems are recorded in a quality log for a single pre-specified sensitivity analysis.
- Left and right foot-sensor files are paired through the trial map, using recording dates and durations, not filenames: the sensors' file counters roll over (99 → 01), so name order is not always recording order. Each pair is checked: left and right durations must agree within 3 s.
- The foot-sensor alignment is trusted only when the left and right time shifts agree.
- Cadence is computed from three independent instruments (shank gyroscopes, foot gyroscopes and forefoot insoles) and cross-checked.
- NAP and Tau-U are tested against the study protocol's worked example on every run, and the AR game's rules are re-checked against its logs on every run.
- All thresholds are fixed constants, identical for every participant.

## Not yet implemented

Swing-phase tibialis anterior EMG, minimum toe clearance, gait speed, and the sensitivity re-analysis based on the quality log.

## Repository structure

```
setup/               Trial-map tools (file listing with durations, trial-map loader)
stage1_emg/          EMG processing and quality log
stage2_sync/         Synchronisation and outcome extraction
stage3_outcomes/     Baseline normalisation, statistics, game and orthosis analyses
```

## Requirements

- MATLAB R2024 or later
- Signal Processing Toolbox and Statistics and Machine Learning Toolbox
- GaitUp Physilog MATLAB toolkit, to read the foot-sensor files (not included; available from GaitUp)
- The orthosis characterisation files used by the torque analysis (not included)

## Acknowledgements

This code was developed at the BioRobotics Group, Centre for Automation and Robotics (CAR, CSIC–UPM), under the supervision of Dr Cristina Bayón. This work was supported by the Dutch Research Council (NWO) under Veni-TTW-2020 grant 18079, and by the Ramón y Cajal contract RYC2023-044613-I funded by MICIU/AEI/10.13039/501100011033 and by the ESF+.

## Rights

Shared for portfolio purposes with the permission of the BioRobotics Group (CAR, CSIC–UPM). All rights reserved.
