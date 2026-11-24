% s1c_MakeWalkWindows_CP03.m
% =========================================================================
% STAGE 1, STEP 3 of 4.
%
% WHAT THIS PROCESSES
%   PAC03\RAW\IMU\gyro_topic_CP03_*.csv   (8 sensors x 3 axes, ~148 Hz)
%   PAC03\PROCESSED\EMG\EMG_CP03_trial*_norm.mat   (for Epoch_ns only)
%   TRIALMAP_CP03.csv                     (to pair them)
%
% WHAT IT ACHIEVES
%   PAC03\PROCESSED\EMG\WINDOWS_CP03.csv with one row per trial:
%       trial, start_s, stop_s      <- consumed by s1d
%       bout_s, clipped, note       <- diagnostics, ignored downstream
%   start_s / stop_s are in EMG-FILE TIME (seconds from the first sample of
%   that trial's EMG CSV), because that is the axis s1d indexes into.
%
% WHY NOT makeWalkWindows.m
%   That function derives the bout from T.angle_l. CP03 has the orthosis on the
%   RIGHT leg only, so there is no left goniometer and angle_l is identically
%   zero in all 30 trials - it would find no bout anywhere. angle_r is not a
%   substitute either: it is flat dead in trials 10, 11, 12, 17 and 18.
%   The Trigno gyros are present and clean in all 30 trials, so we use those.
%
% METHOD
%   1. For each trial, take every gyro sensor that is alive (std > 1 deg/s).
%   2. Per sensor, magnitude = sqrt(x^2+y^2+z^2), scaled by its own 95th
%      percentile so no single sensor dominates. Average across sensors.
%      Averaging makes the detector immune to any one sensor dropping out -
%      which happens in trials 7, 8 and 21.
%   3. Envelope = 1 s moving mean. Threshold = 0.25 * 99th percentile.
%   4. Bout = first to last point where the signal stays above threshold for
%      4 continuous seconds. Trim TRIM seconds inward at each end.
%   5. Convert bout epochs to EMG-file time and CLIP to the EMG that exists.
%      Trials 9 and 14 are truncated recordings; without clipping their window
%      would run past the end of the data.
%
% RUNTIME: ~2-4 minutes.
% =========================================================================

clear; clc;

% ===== USER SETTINGS =====
participant = 'CP03';
TrialMapCsv = 'C:\INVESTIGACION CSIC\PAC03\PROCESSED\TRIALMAP_CP03.csv';
ImuFolder   = 'C:\INVESTIGACION CSIC\PAC03\RAW\IMU';
EmgMatFolder= 'C:\INVESTIGACION CSIC\PAC03\PROCESSED\EMG';
OutCsv      = 'C:\INVESTIGACION CSIC\PAC03\PROCESSED\EMG\WINDOWS_CP03.csv';

TRIM      = 2;      % seconds trimmed inward at each end of the bout
MIN_RUN   = 4;      % seconds of continuous activity required to call it walking
THR_FRAC  = 0.25;   % threshold as a fraction of the 99th percentile envelope
DEAD_STD  = 1.0;    % deg/s; below this a gyro channel counts as not fitted
% =========================

M = readtable(TrialMapCsv, 'TextType','string');
nT = height(M);

fprintf('%-3s %-3s %-9s %8s %8s %8s %10s %10s  %s\n', ...
        'tr','S','sensors','bout_s','won','woff','start_s','stop_s','note');
fprintf('%s\n', repmat('-',1,92));

rows = []; notes = strings(0,1); clipped = [];

for i = 1:nT
    k   = M.trial(i);
    imu = fullfile(ImuFolder, char(M.IMU_file(i)));
    mat = fullfile(EmgMatFolder, sprintf('EMG_%s_trial%d_norm.mat', participant, k));

    if ~isfile(imu)
        fprintf('%-3d  IMU MISSING: %s\n', k, imu); continue;
    end
    if ~isfile(mat)
        fprintf('%-3d  no EMG mat (expected for trial 15) - skipped\n', k); continue;
    end

    % ---- EMG epoch extent for this trial ---------------------------------
    S  = load(mat, 'EMG');
    if ~isfield(S.EMG,'Epoch_ns') || isempty(S.EMG.Epoch_ns)
        error('Trial %d mat has no Epoch_ns. Re-run s1b.', k);
    end
    e0 = double(S.EMG.Epoch_ns(1));
    e1 = double(S.EMG.Epoch_ns(end));

    % ---- Gyro ------------------------------------------------------------
    G  = readtable(imu);
    ts = double(G.ros_timestamp);
    t  = (ts - ts(1)) * 1e-9;
    fs = (numel(t)-1) / t(end);

    live = [];
    for s = 1:8
        sd = max([std(G.(sprintf('gyro%d_x',s))), ...
                  std(G.(sprintf('gyro%d_y',s))), ...
                  std(G.(sprintf('gyro%d_z',s)))]);
        if sd > DEAD_STD, live(end+1) = s; end %#ok<AGROW>
    end
    if isempty(live)
        fprintf('%-3d  NO LIVE GYRO - skipped\n', k); continue;
    end

    mag = zeros(numel(t),1);
    for s = live
        v = sqrt(G.(sprintf('gyro%d_x',s)).^2 + ...
                 G.(sprintf('gyro%d_y',s)).^2 + ...
                 G.(sprintf('gyro%d_z',s)).^2);
        p95 = prctile(v, 95);
        if p95 > 0, mag = mag + v./p95; end
    end
    mag = mag / numel(live);

    w   = max(3, round(1.0*fs));
    env = movmean(mag, w);
    thr = THR_FRAC * prctile(env, 99);
    hot = env > thr;

    run = max(3, round(MIN_RUN*fs));
    ok  = movsum(hot, [0 run-1]) >= run;
    f   = find(ok, 1, 'first');
    l   = find(ok, 1, 'last');
    if isempty(f)
        fprintf('%-3d  NO WALKING BOUT FOUND - skipped\n', k); continue;
    end

    bout_e0 = ts(f);                                  % bout start, absolute epoch
    bout_e1 = ts(min(numel(ts), l + run - 1));        % bout end,   absolute epoch
    bout_s  = (bout_e1 - bout_e0) * 1e-9;

    % ---- Convert to EMG-file time and clip -------------------------------
    start = ceil ((bout_e0 - e0)*1e-9) + TRIM;
    stop  = floor((bout_e1 - e0)*1e-9) - TRIM;

    note = "";
    emgEnd = (e1 - e0)*1e-9;
    if stop > emgEnd - TRIM
        stop = floor(emgEnd) - TRIM;
        note = "CLIPPED to EMG end";
        clipped(end+1) = k; %#ok<AGROW>
    end
    if start < 0
        start = 0;
        note = strtrim(note + " start<0");
    end
    if stop <= start
        fprintf('%-3d  window collapsed (start %.0f >= stop %.0f) - skipped\n', k, start, stop);
        continue;
    end

    fprintf('%-3d %-3d %-9s %8.1f %8.1f %8.1f %10.1f %10.1f  %s\n', ...
            k, M.session(i), mat2str(live), bout_s, ...
            (bout_e0-e0)*1e-9, (bout_e1-e0)*1e-9, start, stop, note);

    rows(end+1,:) = [k, start, stop, bout_s, double(note~="")]; %#ok<AGROW>
    notes(end+1,1) = note; %#ok<AGROW>
end

rows = sortrows(rows,1);
Tout = array2table(rows, 'VariableNames', ...
        {'trial','start_s','stop_s','bout_s','clipped'});
Tout.note = notes;
writetable(Tout, OutCsv);

fprintf('\nSaved %d windows -> %s\n', height(Tout), OutCsv);
fprintf('\nWHAT TO CHECK:\n');
fprintf('  bout_s should be 210-290 s on every trial (a 4-minute walk plus\n');
fprintf('  warm-up). Anything under 150 s means the detector lost the bout.\n');
if ~isempty(clipped)
    fprintf('  Clipped trials: %s. Expected: 9 and 14 (truncated EMG files).\n', mat2str(clipped));
    fprintf('  Any OTHER clipped trial means the EMG stopped early - investigate.\n');
end
fprintf('\nNEXT: run s1d_FindMaxEMG_CP03.m\n');
