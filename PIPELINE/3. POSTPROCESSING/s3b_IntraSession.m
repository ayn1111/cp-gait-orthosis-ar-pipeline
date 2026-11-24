% s3b_IntraSession.m   (v2)
% =========================================================================
% STAGE 3, STEP 2 of 6.   Protocol section 3.1 - intra-session analysis.
%
% WHAT THIS PROCESSES
%   PROCESSED\RESULTS\OUTCOMES_<P>.csv     (from s3a - one row per trial per leg)
%
% WHAT IT ACHIEVES
%   PROCESSED\RESULTS\FIG4\<variable>.png   one figure per variable
%   PROCESSED\RESULTS\INTRASESSION_<P>.csv  the numbers behind every figure:
%       variable, leg, session, condition, n_trials, mean, sd, trial values
%
% WHAT THE PROTOCOL ASKS (section 3.1)
%   "displaying the value of the variable for each walking trial within the
%    session (see Figure 4)". So every walking trial is plotted as its own
%   point, grouped by session, with the session mean drawn through them and
%   the change from baseline (AFO) to intervention (AFO+AR) marked.
%
% WHAT IT CANNOT DO, AND WHY
%   The protocol's within-session AFO-vs-AFO+AR contrast relies on the 2-minute
%   AFO-only control block at the start of each intervention session. That
%   block was not recorded for this participant, so there is no within-session
%   condition contrast to draw: every session contains one condition only.
%   This figure therefore shows the trial-to-trial values within each session
%   and their evolution across sessions. The baseline-vs-intervention contrast
%   is carried by s3d (NAP and Tau-U).
%
% v2 CHANGES
%   - cadence is cadence_steps_min (s2e v6): STEPS per minute, ONE value per
%     trial, so it gets ONE panel labelled "both legs". strideTime_s is no
%     longer plotted: it is exactly 120/cadence and carries nothing new.
%   - a leg with no data for a variable gets no panel (ankle ROM: right only).
%   - SD is blank, not 0, when a session has fewer than two trials.
%   - FIG4\*.png is cleared first, so no figure from an older run survives.
%   - phases are set per SESSION and the session mean uses only the walks of
%     that session's phase condition (protocol 3.3). Identical on CP03, where
%     every session holds one condition; it matters if a control block inside
%     an AR session is ever recorded.
%
% NOTHING IS EXCLUDED. Trials with a missing value (no EMG file, sensor
% dropout, dead goniometer) simply have no point; they are never filled in.
%
% Normalised variables (*_norm) are divided by the baseline reference from
% s3a, so the dotted line at 1.0 is the baseline phase mean. Variables in
% physical units (cadence, ankle ROM) are plotted as they are.
%
% RUNTIME: under a minute.
% =========================================================================

clear; clc; close all;

% ===== USER SETTINGS =====
participant = 'CP03';
Root        = 'C:\INVESTIGACION CSIC\PAC03';
resFolder   = fullfile(Root,'PROCESSED','RESULTS');
outcomesCsv = fullfile(resFolder, sprintf('OUTCOMES_%s.csv', participant));
figFolder   = fullfile(resFolder, 'FIG4');
summaryCsv  = fullfile(resFolder, sprintf('INTRASESSION_%s.csv', participant));

BASELINE_LABEL = "AFO";
INTERV_LABEL   = "AFO_AR";

% {column in OUTCOMES, label, is it baseline-normalised, 'leg' or 'trial' level}
VARS = {
  'pushForce_mean_norm',     'Push-off force (protocol measure)',             true,  'leg'
  'pushForce_ratio_norm',    'Push-off force share of contact (ratio)',       true,  'leg'
  'pushEMG_SOL_norm',        'Soleus EMG at push-off (protocol)',             true,  'leg'
  'pushEMG_SOL_ratio_norm',  'Soleus EMG share at push-off (ratio)',          true,  'leg'
  'pushEMG_GM_norm',         'Gastrocnemius med. EMG at push-off (protocol)', true,  'leg'
  'pushEMG_GM_ratio_norm',   'Gastrocnemius med. EMG share (ratio)',          true,  'leg'
  'pushEMG_TA_norm',         'Tibialis ant. EMG at push-off (protocol)',      true,  'leg'
  'pushEMG_TA_ratio_norm',   'Tibialis ant. EMG share (ratio)',               true,  'leg'
  'cadence_steps_min',       'Cadence (steps/min)',                           false, 'trial'
  'ankleROM_deg',            'Ankle range of motion (deg)',                   false, 'leg'
  };

JITTER   = 0.15;              % horizontal offset between trials of a session
COL_BASE = [0.20 0.45 0.75];  % baseline points
COL_INT  = [0.90 0.50 0.10];  % intervention points
% =========================

if ~isfile(outcomesCsv)
    error('Not found:\n  %s\nRun s3a_BuildOutcomes.m first.', outcomesCsv);
end
if ~exist(figFolder,'dir'), mkdir(figFolder); end
old = dir(fullfile(figFolder, '*.png'));       % no stale figure from an older run
for q = 1:numel(old), delete(fullfile(old(q).folder, old(q).name)); end

O = readtable(outcomesCsv, 'TextType','string');
need = {'trial','session','condition','leg'};
miss = setdiff(need, O.Properties.VariableNames);
if ~isempty(miss), error('OUTCOMES is missing column(s): %s', strjoin(miss,', ')); end
if ~ismember('cadence_steps_min', O.Properties.VariableNames)
    error(['OUTCOMES has no cadence_steps_min - it was built by s3a v2 or earlier. ' ...
           'Run s2c v2, s2e v6 and s3a v3 first.']);
end

sessions   = unique(O.session)';
% Phases per SESSION: any AFO+AR walk makes it an intervention session. Within
% a session only the walks of its phase's condition enter the session mean.
intSess    = unique(O.session(O.condition == INTERV_LABEL))';
baseSess   = setdiff(unique(O.session(O.condition == BASELINE_LABEL))', intSess);
inPhase    = (O.condition == BASELINE_LABEL & ismember(O.session, baseSess)) | ...
             (O.condition == INTERV_LABEL   & ismember(O.session, intSess));
phaseLine  = max(baseSess) + 0.5;
fprintf('Baseline sessions %s | intervention sessions %s\n\n', ...
        mat2str(baseSess), mat2str(intSess));

% Position of each trial within its session (1st, 2nd, 3rd walk), from the
% trial number, so the jitter reflects the order the walks were performed.
O.walkInSession = zeros(height(O),1);
for s = sessions
    tr = unique(O.trial(O.session == s));
    for j = 1:numel(tr)
        O.walkInSession(O.trial == tr(j)) = j;
    end
end

sumRows = {};
for v = 1:size(VARS,1)
    col = VARS{v,1}; lab = VARS{v,2}; isNorm = VARS{v,3}; level = string(VARS{v,4});
    if ~ismember(col, O.Properties.VariableNames)
        fprintf('%-26s not in OUTCOMES - skipped\n', col); continue;
    end
    if level == "trial", checkTrialLevel(O, col); legs = "B"; else, legs = ["L","R"]; end
    legsWithData = strings(0);
    for lg = legs
        if any(isfinite(O.(col)(legMask(O, lg)))), legsWithData(end+1) = lg; end %#ok<AGROW>
    end
    if isempty(legsWithData)
        fprintf('%-26s no data on any leg - skipped\n', col); continue;
    end

    fig = figure('Color','w','Visible','off', ...
                 'Position',[100 100 650*numel(legsWithData) 480]);
    tl  = tiledlayout(1, numel(legsWithData), 'TileSpacing','compact');
    title(tl, sprintf('%s - %s', lab, participant), 'FontWeight','bold');

    for lg = legsWithData
        nexttile; hold on; grid on; box on;
        m  = legMask(O, lg);
        y  = O.(col)(m);
        x  = O.session(m) + (O.walkInSession(m) - 2) * JITTER;
        ib = O.condition(m) == BASELINE_LABEL;

        scatter(x(ib),  y(ib),  36, COL_BASE, 'filled', 'MarkerFaceAlpha', 0.85);
        scatter(x(~ib), y(~ib), 36, COL_INT,  'filled', 'MarkerFaceAlpha', 0.85);

        sm = nan(size(sessions));
        for j = 1:numel(sessions)
            s  = sessions(j);
            ms = m & O.session == s & inPhase;     % the session's data point
            if ~any(ms), continue; end
            ys = O.(col)(ms);
            ok = isfinite(ys);
            sdv = NaN;
            if any(ok), sm(j) = mean(ys(ok)); end
            if nnz(ok) >= 2, sdv = std(ys(ok)); end        % SD needs two trials
            cond = O.condition(find(ms,1));
            % trial values in walk order, for the summary table
            [~, ord] = sort(O.walkInSession(ms));
            yv = ys(ord);
            sumRows(end+1,:) = {string(col), lg, s, cond, nnz(ok), sm(j), ...
                                sdv, strjoin(compose('%.4g', yv'), '; ')}; %#ok<AGROW>
        end
        plot(sessions, sm, 'k-', 'LineWidth', 1.4);
        plot(sessions, sm, 'ks', 'MarkerFaceColor','w', 'MarkerSize', 6);

        xline(phaseLine, '--', 'AR starts', 'LabelVerticalAlignment','bottom', ...
              'Color',[0.4 0.4 0.4]);
        if isNorm, yline(1, ':', 'baseline mean', 'Color',[0.4 0.4 0.4]); end
        xlim([min(sessions)-0.6, max(sessions)+0.6]);
        xticks(sessions);
        xlabel('Session');
        if isNorm, ylabel('normalised to baseline'); else, ylabel(lab); end
        title(legTitle(lg));
        legend({'AFO (baseline)','AFO+AR','session mean'}, 'Location','best');
    end

    exportgraphics(fig, fullfile(figFolder, [col '.png']), 'Resolution', 150);
    close(fig);
    fprintf('%-26s -> FIG4\\%s.png\n', col, col);
end

S = cell2table(sumRows, 'VariableNames', ...
      {'variable','leg','session','condition','n_trials','mean','sd','trial_values'});
writetable(S, summaryCsv);
fprintf('\nSaved -> %s\n', summaryCsv);

% ---- console summary for the headline variables ----
fprintf('\n=== SESSION MEANS (headline variables) ===\n');
for col = ["pushForce_mean_norm","pushForce_ratio_norm","cadence_steps_min"]
    for lg = unique(S.leg(S.variable == col))'
        r = S(S.variable == col & S.leg == lg, :);
        fprintf('%-22s %s  %s\n', col, lg, strjoin(compose('S%d=%.2f', r.session, r.mean)', '  '));
    end
end
fprintf(['\nLeg "B" = both legs: a trial-level variable (one value per trial).\n' ...
         'Each session mean here must equal the one s3a printed for the same\n' ...
         'variable. If they differ, OUTCOMES changed between the two runs.\n']);

% ===== helpers =====
function out = ternary(c,a,b), if c, out = a; else, out = b; end, end

function m = legMask(O, lg)
% Rows that carry a leg's values. "B" = a trial-level variable: s3a writes
% the same value on both rows of a trial, so the right-leg rows hold it.
    if lg == "B", m = O.leg == "R"; else, m = O.leg == lg; end
end

function s = legTitle(lg)
    if lg == "B"
        s = 'Both legs (one value per trial)';
    else
        s = sprintf('%s leg', ternary(lg == "L", 'Left', 'Right'));
    end
end

function checkTrialLevel(O, col)
% A trial-level variable must hold the same value on both rows of a trial.
    for k = unique(O.trial)'
        x = O.(col)(O.trial == k);
        x = x(isfinite(x));
        if numel(x) > 1 && max(x) - min(x) > 1e-9*max(1, max(abs(x)))
            error('Trial %d: %s differs between legs. Re-run s3a v3.', k, col);
        end
    end
end
