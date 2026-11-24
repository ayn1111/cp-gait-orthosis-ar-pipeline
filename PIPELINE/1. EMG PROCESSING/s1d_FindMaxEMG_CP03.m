% s1d_FindMaxEMG_CP03.m
% =========================================================================
% STAGE 1, STEP 4 of 4.
%
% WHAT THIS PROCESSES
%   PAC03\PROCESSED\EMG\EMG_CP03_trial<k>_norm.mat   (PASS 1 output: RAW envelopes)
%   PAC03\PROCESSED\EMG\WINDOWS_CP03.csv             (walking window per trial)
%
% WHAT IT ACHIEVES
%   PAC03\PROCESSED\EMG\EMG_CP03_maximum.mat, holding one value per channel:
%       maximums(ch) = the peak envelope amplitude that channel ever reached
%                      during walking, across ALL 30 trials.
%   Every EMG value in the study is then expressed as a fraction of this.
%
% ================ READ THIS BEFORE RUNNING ================
% This step is IRREVERSIBLE in the sense that matters. The maxima must be
% computed ONCE, from a FIXED set of trials, and applied unchanged to all of
% them. If you recompute later over a different set, every previously
% normalized value becomes incomparable and the whole study must be reprocessed.
%
%   -> mvcTrials is 1:30, i.e. ALL sessions, baseline AND intervention.
%   -> It must stay 1:30. Do not narrow it to the baseline sessions: the peak
%      plantar-flexor activity almost certainly occurs during the AR sessions,
%      and normalizing by a baseline-only maximum would push intervention
%      values above 1.0 and distort the effect size.
%   -> The envelopes it reads MUST be non-normalized. The script refuses to run
%      if it detects normalized input.
% ==========================================================
%
% NOTE ON usePercentile
%   A_ReadDelsysEMG's low-pass at 3 Hz means the envelope cannot contain
%   single-sample spikes, so a percentile cap does remove some real signal.
%   But CP03 has confirmed motion artifacts (sensor dropouts, a 40%-pause
%   session), and an uncapped max would sit on the largest artifact bump in
%   2.3 GB of data. We keep the cap at 99.5 and record the setting in the
%   output file so the choice is auditable. Whatever you choose, it must be
%   the same for every channel and every trial - which it is here.
%
% RUNTIME: ~5-10 minutes with MAKE_PLOTS = false.
% =========================================================================

clear; clc;

% ===== USER SETTINGS =====
participant = 'CP03';
MatFolder   = 'C:\INVESTIGACION CSIC\PAC03\PROCESSED\EMG';
WindowCsv   = 'C:\INVESTIGACION CSIC\PAC03\PROCESSED\EMG\WINDOWS_CP03.csv';

mvcTrials     = 1:30;      % ALL trials. See the warning above.
SensorsNames  = {'GL_l','TA_l','GM_r','SOL_l','SOL_r','GL_r','GM_l','TA_r'};
inactiveChannelsManual = [1 6];

usePercentile = true;      % see NOTE above
pctl          = 99.5;
threshold     = Inf;       % optional hard cap; Inf = disabled
MAKE_PLOTS    = false;     % 30 figures. Keep false.
% =========================

nCh      = numel(SensorsNames);
SaveBase = sprintf('EMG_%s', participant);
outFile  = fullfile(MatFolder, sprintf('%s_maximum.mat', SaveBase));

if exist(outFile,'file')
    fprintf('WARNING: %s already exists and will be OVERWRITTEN.\n', outFile);
    fprintf('If any trial mat has already been normalized with it, delete every\n');
    fprintf('EMG_%s_trial*_norm.mat and re-run s1b PASS 1 first.\n\n', participant);
end

% ---- Windows -------------------------------------------------------------
if ~isfile(WindowCsv)
    error('Window file not found. Run s1c first:\n  %s', WindowCsv);
end
W = readtable(WindowCsv);

% ---- Which trial mats exist ---------------------------------------------
mats = arrayfun(@(k) sprintf('EMG_%s_trial%d_norm.mat', participant, k), ...
                mvcTrials, 'uni', 0);
present = cellfun(@(f) isfile(fullfile(MatFolder,f)), mats);
for i = find(~present)
    fprintf('Trial %d: no mat (expected for trial 15) - skipped\n', mvcTrials(i));
end
mats        = mats(present);
trialsUsed  = mvcTrials(present);
if isempty(mats), error('No trial mats found in %s', MatFolder); end

% ---- Guard: input must be NON-normalized --------------------------------
S0 = load(fullfile(MatFolder, mats{1}), 'EMG');
if isfield(S0.EMG,'Normalized') && S0.EMG.Normalized
    error(['%s is ALREADY NORMALIZED. Delete %s and every ' ...
           'EMG_%s_trial*_norm.mat, then re-run s1b (PASS 1).'], ...
           mats{1}, outFile, participant);
end

if isfield(S0.EMG,'InactiveChannels')
    inactiveChannels = S0.EMG.InactiveChannels(:).';
else
    inactiveChannels = inactiveChannelsManual;
end
activeCh = setdiff(1:nCh, inactiveChannels);
fprintf('\nActive channels: %s | inactive: %s\n', ...
        strjoin(SensorsNames(activeCh),', '), strjoin(SensorsNames(inactiveChannels),', '));
fprintf('Pooling maxima over %d trials.\n\n', numel(trialsUsed));

% ---- Accumulate ----------------------------------------------------------
maximums           = nan(1, nCh);
maximums(activeCh) = 0;
argmaxTrial        = nan(1, nCh);       % which trial produced each maximum
perTrial           = nan(numel(mats), nCh);

fprintf('%-3s %-3s %8s %8s   %s\n','tr','S','win_st','win_sp','per-channel max (NaN = dead)');
fprintf('%s\n', repmat('-',1,100));

for i = 1:numel(mats)
    k   = trialsUsed(i);
    S   = load(fullfile(MatFolder, mats{i}), 'EMG');
    EMG = S.EMG;
    t   = EMG.Time(:);
    env = EMG.Norm;

    wRow = find(W.trial == k, 1);
    if isempty(wRow)
        warning('Trial %d has no window in %s - skipped.', k, WindowCsv); continue;
    end
    st_sec = W.start_s(wRow);
    en_sec = W.stop_s(wRow);

    st_idx = find(t >= st_sec, 1, 'first');
    en_idx = find(t <= en_sec, 1, 'last');
    if isempty(st_idx) || isempty(en_idx) || en_idx <= st_idx
        warning('Trial %d: window %.0f-%.0f s falls outside the data - skipped.', ...
                k, st_sec, en_sec); continue;
    end
    envw = env(st_idx:en_idx, :);
    if isfinite(threshold), envw(envw > threshold) = NaN; end

    deadThis = [];
    if isfield(EMG,'DeadThisTrial'), deadThis = EMG.DeadThisTrial; end

    max_trial = nan(1, nCh);
    for ch = activeCh
        if ismember(ch, deadThis), continue; end     % sensor absent this trial
        x = envw(:,ch); x = x(~isnan(x));
        if isempty(x), continue; end
        if usePercentile
            cap = prctile(x, pctl);
            max_trial(ch) = max(x(x <= cap), [], 'omitnan');
        else
            max_trial(ch) = max(x, [], 'omitnan');
        end
    end

    perTrial(i,:) = max_trial;
    for ch = activeCh
        if isfinite(max_trial(ch)) && max_trial(ch) > maximums(ch)
            maximums(ch)    = max_trial(ch);
            argmaxTrial(ch) = k;
        end
    end

    sess = ''; if isfield(EMG,'Session'), sess = num2str(EMG.Session); end
    fprintf('%-3d %-3s %8.0f %8.0f   %s\n', k, sess, st_sec, en_sec, ...
            strjoin(arrayfun(@(v) sprintf('%8.2e',v), max_trial, 'uni',0), ' '));

    if MAKE_PLOTS
        figure('Color','w','Name',sprintf('Trial %d max overlay',k));
        for ch = 1:nCh
            subplot(2,4,ch);
            if ismember(ch, inactiveChannels) || ismember(ch, deadThis)
                axis off; text(0.5,0.5,sprintf('%s\n(no sensor)',SensorsNames{ch}), ...
                    'HorizontalAlignment','center','Units','normalized'); continue;
            end
            plot(t, env(:,ch)); hold on; grid on;
            xline(st_sec,'g'); xline(en_sec,'g');
            if isfinite(max_trial(ch)), yline(max_trial(ch),'r--'); end
            title(SensorsNames{ch}); xlabel('Time [s]');
        end
    end
end

maximums(inactiveChannels) = NaN;

% ---- Report --------------------------------------------------------------
fprintf('\n=== POOLED MAXIMA ===\n');
for ch = 1:nCh
    if isnan(maximums(ch))
        fprintf('  %-6s   (no sensor fitted)\n', SensorsNames{ch});
    else
        col = perTrial(:,ch); col = col(isfinite(col));
        fprintf('  %-6s %10.4e   from trial %2d   | across trials: min %.2e, median %.2e\n', ...
                SensorsNames{ch}, maximums(ch), argmaxTrial(ch), min(col), median(col));
    end
end

% ---- Sanity checks -------------------------------------------------------
fprintf('\n=== CHECKS ===\n');
act = maximums(activeCh);
if any(act <= 0)
    fprintf('  FAIL: a channel has max <= 0. Division would produce Inf.\n');
end
if any(act >= 0.9 & act <= 2)
    fprintf('  WARNING: maxima near 1.0 - you may have run on normalized data.\n');
end
for ch = activeCh
    col = perTrial(:,ch); col = col(isfinite(col));
    if isempty(col), continue; end
    if maximums(ch) > 4*median(col)
        fprintf('  WARNING: %s max (%.2e, trial %d) is >4x the median trial max (%.2e).\n', ...
                SensorsNames{ch}, maximums(ch), argmaxTrial(ch), median(col));
        fprintf('           Inspect that trial with MAKE_PLOTS = true before accepting.\n');
    end
end

% ---- Save ----------------------------------------------------------------
meta = struct('participant',participant,'trialsUsed',trialsUsed, ...
              'usePercentile',usePercentile,'pctl',pctl, ...
              'argmaxTrial',argmaxTrial,'perTrialMax',perTrial, ...
              'windowCsv',WindowCsv,'created',datestr(now));
save(outFile, 'maximums', 'meta');
fprintf('\nSaved -> %s\n', outFile);
fprintf('\nNEXT: run s1b_ReadDelsysEMG_CP03.m again (PASS 2) to normalize.\n');
