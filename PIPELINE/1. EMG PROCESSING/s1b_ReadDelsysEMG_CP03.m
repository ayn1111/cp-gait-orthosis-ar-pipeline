% s1b_ReadDelsysEMG_CP03.m
% =========================================================================
% STAGE 1, STEP 2 of 4.   RUN THIS TWICE (see PASS below).
%
% WHAT THIS PROCESSES
%   The 30 cleaned CSVs from s1a, listed in TRIALMAP_CP03.csv.
%   Trial numbers come from the map, NOT from a dir() listing, so trial k here
%   is the same trial k in every other script and in every output table.
%
% WHAT IT ACHIEVES
%   PAC03\PROCESSED\EMG\EMG_CP03_trial<k>_norm.mat, one per trial, containing:
%       EMG.Time             uniform device-rate time, 0-based        [N x 1]
%       EMG.Epoch_ns         absolute ROS epoch per sample            [N x 1]
%       EMG.Norm             linear envelope per channel              [N x 8]
%       EMG.Labels           channel -> muscle names                  {1 x 8}
%       EMG.InactiveChannels channels with no sensor fitted           [1 6]
%       EMG.DeadThisTrial    channels flat-zero in THIS trial only
%       EMG.Frequencies.EMG  device sample rate
%
% PASS 1 (now):   no EMG_CP03_maximum.mat exists -> EMG.Norm holds RAW envelopes.
% PASS 2 (later): after s1d has written the maxima -> EMG.Norm is divided by
%                 them, giving normalized envelopes.
%   The script detects which pass it is on and prints it. Do not skip pass 1:
%   the maxima in step 1.4 must be computed from NON-normalized envelopes.
%
% PROCESSING CHAIN PER CHANNEL
%   remove DC -> Butterworth band-pass 30-300 Hz (2nd order, zero-lag)
%   -> full-wave rectify -> Butterworth low-pass 3 Hz (2nd order, zero-lag)
%   This is unchanged from A_ReadDelsysEMG.m. Only the plumbing around it changed.
%
% RUNTIME: ~10-20 min for 30 trials with MAKE_PLOTS = false.
% =========================================================================

clear; close all; clc;

% ===== USER SETTINGS =====
participant = 'CP03';

TrialMapCsv = 'C:\INVESTIGACION CSIC\PAC03\PROCESSED\TRIALMAP_CP03.csv';
CleanPath   = 'C:\INVESTIGACION CSIC\PAC03\PROCESSED\EMG_CLEAN';
SaveFolder  = 'C:\INVESTIGACION CSIC\PAC03\PROCESSED\EMG';
HelperPath  = 'C:\INVESTIGACION CSIC\Data analysis\1. EMG Processing';   % ZeroLagButtFiltfilt.m

% Channel layout, emg1..emg8. CONFIRMED identical to P001 for this participant.
SensorsNames     = {'GL_l','TA_l','GM_r','SOL_l','SOL_r','GL_r','GM_l','TA_r'};

% Channels with no sensor fitted for the whole study.
%   emg1 = GL_l, emg6 = GL_r  (gastrocnemius lateralis, both sides)
% Verified empirically: std is exactly 0 in all 30 EMG files AND in all 30 gyro
% files for sensors 1 and 6, which is what you see when a Trigno sensor is absent.
inactiveChannels = [1 6];

deadFill   = NaN;    % what to write for channels with no sensor
MAKE_PLOTS = false;  % 30 trials x 8 subplots x up to 1.4M points. Keep false.
SAVE_RAW   = false;  % also store unfiltered EMG in the mat. false keeps mats
                     % ~40 MB instead of ~80 MB; the clean CSV is still on disk.
Save       = 1;
% =========================

matBase     = sprintf('EMG_%s_trial', participant);
MaxFileBase = sprintf('EMG_%s', participant);
maxFile     = fullfile(SaveFolder, sprintf('%s_maximum.mat', MaxFileBase));

% ---- Which pass are we on? ----------------------------------------------
if exist(maxFile,'file')
    fprintf('=== PASS 2: %s found. Envelopes WILL be normalized. ===\n\n', maxFile);
    S = load(maxFile); maximums = S.maximums(:).';
else
    fprintf('=== PASS 1: no maxima file. Saving NON-normalized envelopes. ===\n');
    fprintf('    Run s1c then s1d, then run this script again.\n\n');
    maximums = [];
end

% ---- Helper path ---------------------------------------------------------
if exist(HelperPath,'dir'), addpath(HelperPath); end
if ~exist('ZeroLagButtFiltfilt','file')
    error('ZeroLagButtFiltfilt.m not found. Fix HelperPath.');
end
if ~exist(SaveFolder,'dir'), mkdir(SaveFolder); end

% ---- Trial map -----------------------------------------------------------
if ~isfile(TrialMapCsv), error('Trial map not found: %s', TrialMapCsv); end
M = readtable(TrialMapCsv, 'TextType','string');
nTrials = height(M);
fprintf('Trial map: %d trials, sessions %d-%d\n\n', nTrials, min(M.session), max(M.session));

nCh      = numel(SensorsNames);
activeCh = setdiff(1:nCh, inactiveChannels);
skipped  = [];

% ===== Main loop ==========================================================
for iRow = 1:nTrials
    k       = M.trial(iRow);
    csvName = char(M.EMG_file(iRow));
    fullfn  = fullfile(CleanPath, csvName);

    fprintf('--- Trial %2d (session %d, %s) | %s\n', ...
            k, M.session(iRow), M.condition(iRow), csvName);

    if ~exist(fullfn,'file')
        warning('  MISSING: %s  -> trial %d skipped', fullfn, k);
        skipped(end+1) = k; %#ok<AGROW>
        continue;
    end

    try
        T = readtable(fullfn, 'Delimiter', ',', 'TextType','string');
    catch ME
        warning('  READ FAILED (%s) -> trial %d skipped', ME.message, k);
        skipped(end+1) = k; %#ok<AGROW>
        continue;
    end

    if height(T) < 1000
        warning('  Only %d rows -> trial %d skipped (no usable EMG)', height(T), k);
        skipped(end+1) = k; %#ok<AGROW>
        continue;
    end

    emgCols = find(startsWith(lower(T.Properties.VariableNames), 'emg'));
    if numel(emgCols) ~= 8
        warning('  Expected 8 EMG columns, found %d', numel(emgCols));
    end

    epoch_ns   = double(T.timestamp_ns);
    dataEmgRaw = T{:, emgCols};

    valid      = all(~isnan(dataEmgRaw),2) & ~isnan(epoch_ns);
    dataEmgRaw = dataEmgRaw(valid,:);
    epoch_ns   = epoch_ns(valid);

    % Device rate from the TOTAL SPAN, not median(diff). The ROS timestamps are
    % quantised, so median spacing locks onto the quantisation step and
    % underestimates fs. Span over (N-1) intervals recovers the true rate.
    N  = size(dataEmgRaw,1);
    fs = (N-1) / ((epoch_ns(end)-epoch_ns(1))*1e-9);
    t  = (0:N-1)'/fs;                 % uniform, monotonic, unique
    epoch_ns = epoch_ns(1) + round((0:N-1)'/fs*1e9);
    fprintf('    fs = %.2f Hz | %d samples (%.1f s)\n', fs, N, t(end));

    % ---- Detect channels that are flat-zero in THIS trial ----------------
    % A Trigno sensor that drops out mid-study zeroes both its EMG and its
    % gyro for the whole trial. Detecting it here means no hard-coded lists.
    deadThis = [];
    for ch = activeCh
        if all(dataEmgRaw(:,ch) == 0)
            deadThis(end+1) = ch; %#ok<AGROW>
        end
    end
    if ~isempty(deadThis)
        fprintf('    SENSOR DROPOUT this trial: %s (channels %s)\n', ...
                strjoin(SensorsNames(deadThis), ', '), mat2str(deadThis));
    end

    % ---- Package ---------------------------------------------------------
    EMG                  = struct();
    EMG.Time             = t;
    EMG.Epoch_ns         = epoch_ns;
    EMG.Labels           = SensorsNames;
    EMG.Frequencies.EMG  = fs;
    EMG.NumberOfSensors  = nCh;
    EMG.ActiveChannels   = activeCh;
    EMG.InactiveChannels = inactiveChannels;
    EMG.DeadThisTrial    = deadThis;
    EMG.TrialNumber      = k;
    EMG.Session          = M.session(iRow);
    EMG.Condition        = M.condition(iRow);
    if SAVE_RAW, EMG.AnalogData = dataEmgRaw; end

    % ---- Filter ----------------------------------------------------------
    bp_lo = 30;
    bp_hi = min(300, 0.6*(fs/2));
    if bp_hi <= bp_lo, bp_hi = 0.9*(fs/2); end

    EMGData = nan(size(dataEmgRaw));
    if MAKE_PLOTS
        figure('Name',sprintf('Trial %d - %s',k,csvName),'Color','w');
    end

    for ch = 1:nCh
        if ismember(ch, inactiveChannels) || ismember(ch, deadThis)
            continue;                        % leave as NaN
        end
        x    = double(dataEmgRaw(:,ch));
        x    = x - mean(x,'omitnan');
        BP   = ZeroLagButtFiltfilt(1/fs, [bp_lo bp_hi], 2, 'bp', x);
        Env  = ZeroLagButtFiltfilt(1/fs, 3, 2, 'lp', abs(BP));
        EMGData(:,ch) = Env;

        if MAKE_PLOTS
            subplot(2,4,ch);
            plot(t,x); hold on; plot(t,Env,'LineWidth',1.5);
            title(SensorsNames{ch}); xlabel('Time [s]'); grid on;
        end
    end

    EMGData(:, inactiveChannels) = deadFill;
    EMGData(:, deadThis)         = deadFill;
    EMG.Norm = EMGData;

    % ---- Normalize (pass 2 only) -----------------------------------------
    if ~isempty(maximums)
        for ch = activeCh
            if ismember(ch, deadThis), continue; end
            if isfinite(maximums(ch)) && maximums(ch) > 0
                EMG.Norm(:,ch) = EMGData(:,ch) ./ maximums(ch);
            end
        end
        EMG.Norm(:, inactiveChannels) = deadFill;
        EMG.Norm(:, deadThis)         = deadFill;
        EMG.Normalized = true;
        fprintf('    normalized using %s\n', maxFile);
    else
        EMG.Normalized = false;
    end

    if Save
        fn = fullfile(SaveFolder, sprintf('%s%d_norm.mat', matBase, k));
        save(fn, 'EMG', '-v7.3');
        fprintf('    saved %s\n', fn);
    end
end

fprintf('\n=== DONE ===\n');
if isempty(skipped)
    fprintf('All %d trials written.\n', nTrials);
else
    fprintf('Written: %d | Skipped: %s\n', nTrials-numel(skipped), mat2str(skipped));
    fprintf('Expected skip: trial 15 (emg_20260831_191231.csv is entirely NUL).\n');
end
if isempty(maximums)
    fprintf('\nNEXT: run s1c_MakeWalkWindows_CP03.m\n');
else
    fprintf('\nSTAGE 1 COMPLETE. Envelopes are normalized.\n');
end
