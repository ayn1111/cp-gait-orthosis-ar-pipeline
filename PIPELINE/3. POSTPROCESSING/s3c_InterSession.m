% s3c_InterSession.m   (v2)
% =========================================================================
% STAGE 3, STEP 3 of 6.   Protocol section 3.2 - inter-session analysis.
%
% WHAT THIS PROCESSES
%   PROCESSED\RESULTS\OUTCOMES_<P>.csv     (from s3a)
%
% WHAT IT ACHIEVES
%   PROCESSED\RESULTS\FIG5\<variable>.png   one figure per variable
%   PROCESSED\RESULTS\INTERSESSION_<P>.csv  per session: mean, SD, CV, n
%   PROCESSED\RESULTS\PHASES_<P>.csv        per phase: mean, SD and CV of the
%                                           session means, and the slope
%   PROCESSED\RESULTS\WALKORDER_<P>.csv     the Control / AR1 / AR2 / AR3 values
%
% WHAT THE PROTOCOL ASKS (section 3.2)
%   "The evolution of the outcome variables across sessions was analyzed
%    using the mean values per session for each variable (see Figure 5).
%    Temporal trends were evaluated through visual analysis of the series
%    and intra-subject variability through descriptive statistics such as
%    standard deviation or coefficient of variation."
%
% THE TEXT AND THE EXAMPLE FIGURE DISAGREE, SO BOTH ARE PRODUCED
%   The text describes session means over time. The example Figure 5 has an
%   x-axis of Control, AR1, AR2, AR3 - the control block, then the three AR
%   walks of an intervention session. Each figure here therefore has:
%
%   Panel A  session means +/- SD across all sessions, with each phase's
%            mean drawn as a horizontal line. This is what the TEXT asks.
%   Panel B  Control, AR1, AR2, AR3, adapted to what was recorded. The 2-min
%            control block was NOT recorded for this participant, so:
%              Control = mean of the baseline (AFO) session means
%              AR1     = the 1st AR walk of each AR session, averaged across
%                        AR sessions (AR2, AR3 likewise)
%            Error bars are the SD across sessions. This is what the example
%            FIGURE shows, as closely as the data allow, and it answers a
%            real question: does the effect build or fade across the three
%            walks of a session?
%
% UNIT OF ANALYSIS
%   Phase statistics are computed on SESSION MEANS, not on individual trials,
%   because section 3.3 defines each NAP / Tau-U data point as "the mean value
%   of a variable obtained during a session". SD and CV across session means
%   are the intra-subject variability the protocol asks for.
%
%   slope = least-squares slope of the session means against session number,
%   within each phase, in units per session. It is descriptive support for
%   the visual trend analysis, not a test. A non-zero BASELINE slope is the
%   thing Tau-U corrects for.
%
% v2 CHANGES
%   - cadence is cadence_steps_min (s2e v6), one value per trial, one panel
%     row labelled "both legs". strideTime_s is dropped (= 120/cadence).
%   - any SD (and so CV) built from fewer than two values is blank, not 0.
%   - legend moved below the axes so it cannot cover a data point.
%   - FIG5\*.png is cleared first, so no figure from an older run survives.
%   - phases are set per SESSION and session means use only the walks of
%     that session's phase condition (protocol 3.3); AR1-AR3 count only AR
%     walks. Identical on CP03, where every session holds one condition.
%
% NOTHING IS EXCLUDED. A session whose trials are all NaN has no mean and
% does not enter the phase statistics; the n columns record exactly what did.
%
% RUNTIME: under a minute.
% =========================================================================

clear; clc; close all;

% ===== USER SETTINGS =====
participant = 'CP03';
Root        = 'C:\INVESTIGACION CSIC\PAC03';
resFolder   = fullfile(Root,'PROCESSED','RESULTS');
outcomesCsv = fullfile(resFolder, sprintf('OUTCOMES_%s.csv', participant));
figFolder   = fullfile(resFolder, 'FIG5');

BASELINE_LABEL = "AFO";
INTERV_LABEL   = "AFO_AR";

% Same variable list as s3b, so Figures 4 and 5 always cover the same outcomes.
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

COL_BASE = [0.20 0.45 0.75];
COL_INT  = [0.90 0.50 0.10];
% =========================

if ~isfile(outcomesCsv)
    error('Not found:\n  %s\nRun s3a_BuildOutcomes.m first.', outcomesCsv);
end
if ~exist(figFolder,'dir'), mkdir(figFolder); end
old = dir(fullfile(figFolder, '*.png'));       % no stale figure from an older run
for q = 1:numel(old), delete(fullfile(old(q).folder, old(q).name)); end

O = readtable(outcomesCsv, 'TextType','string');
if ~ismember('cadence_steps_min', O.Properties.VariableNames)
    error(['OUTCOMES has no cadence_steps_min - it was built by s3a v2 or earlier. ' ...
           'Run s2c v2, s2e v6 and s3a v3 first.']);
end

sessions = unique(O.session)';
% Phases per SESSION: any AFO+AR walk makes it an intervention session. Within
% a session only the walks of its phase's condition enter the session mean.
intSess  = unique(O.session(O.condition == INTERV_LABEL))';
baseSess = setdiff(unique(O.session(O.condition == BASELINE_LABEL))', intSess);
inPhase  = (O.condition == BASELINE_LABEL & ismember(O.session, baseSess)) | ...
           (O.condition == INTERV_LABEL   & ismember(O.session, intSess));
phaseLine = max(baseSess) + 0.5;

% walk order within each session (1st, 2nd, 3rd walk of the session's phase
% condition), from the trial number
O.walk = zeros(height(O),1);
for s = sessions
    tr = unique(O.trial(O.session == s & inPhase));
    for j = 1:numel(tr), O.walk(O.trial == tr(j)) = j; end
end
nWalk = max(O.walk);

sesRows = {}; phRows = {}; wkRows = {};

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
    if isempty(legsWithData), continue; end

    fig = figure('Color','w','Visible','off', ...
                 'Position',[100 100 1350 450*numel(legsWithData)]);
    tl  = tiledlayout(numel(legsWithData), 2, 'TileSpacing','compact');
    title(tl, sprintf('%s - %s', lab, participant), 'FontWeight','bold');

    for lg = legsWithData
        m = legMask(O, lg);
        legName = legTitle(lg);

        % ---------- per-session statistics ----------
        mu = nan(size(sessions)); sd = mu; cv = mu; nn = zeros(size(sessions));
        for j = 1:numel(sessions)
            ys = O.(col)(m & O.session == sessions(j) & inPhase);
            ys = ys(isfinite(ys));
            nn(j) = numel(ys);
            if nn(j) >= 1, mu(j) = mean(ys); end
            if nn(j) >= 2                                % SD needs two trials
                sd(j) = std(ys);
                cv(j) = 100*sd(j)/abs(mu(j));
            end
            cond = ternary(ismember(sessions(j), baseSess), BASELINE_LABEL, INTERV_LABEL);
            sesRows(end+1,:) = {string(col), lg, sessions(j), cond, nn(j), ...
                                mu(j), sd(j), cv(j)}; %#ok<AGROW>
        end

        % ---------- per-phase statistics, on SESSION MEANS ----------
        phM = struct();
        for ph = [BASELINE_LABEL, INTERV_LABEL]
            pSess = ternary(ph == BASELINE_LABEL, baseSess, intSess);
            k  = ismember(sessions, pSess) & isfinite(mu);
            x  = sessions(k); y = mu(k);
            pm = NaN; psd = NaN; pcv = NaN; slope = NaN;
            if ~isempty(y), pm = mean(y); end
            if numel(y) >= 2
                psd = std(y); pcv = 100*psd/abs(pm);
                pf = polyfit(x, y, 1); slope = pf(1);
            end
            phM.(char(ph)) = pm;
            phRows(end+1,:) = {string(col), lg, ph, numel(y), ...
                               joinNums(x, ','), pm, psd, pcv, slope}; %#ok<AGROW>
        end

        % ---------- Control / AR1 / AR2 / AR3 ----------
        % Control = the baseline phase, one value per baseline session.
        % ARw     = walk w of each AR session, one value per AR session.
        grp  = ["Control", "AR" + string(1:nWalk)];
        gMu  = nan(1, numel(grp)); gSd = gMu; gN = zeros(1, numel(grp));
        vals = mu(ismember(sessions, baseSess)); vals = vals(isfinite(vals));
        gN(1) = numel(vals);
        if gN(1) >= 1, gMu(1) = mean(vals); end
        if gN(1) >= 2, gSd(1) = std(vals); end
        for w = 1:nWalk
            vals = O.(col)(m & inPhase & ismember(O.session, intSess) & O.walk == w);
            vals = vals(isfinite(vals));
            gN(w+1) = numel(vals);
            if gN(w+1) >= 1, gMu(w+1) = mean(vals); end
            if gN(w+1) >= 2, gSd(w+1) = std(vals); end
        end
        for g = 1:numel(grp)
            wkRows(end+1,:) = {string(col), lg, grp(g), gN(g), gMu(g), gSd(g)}; %#ok<AGROW>
        end

        % ---------- Panel A: session means across sessions ----------
        nexttile; hold on; grid on; box on;
        isB = ismember(sessions, baseSess);
        errorbar(sessions(isB),  mu(isB),  sd(isB),  'o', 'Color', COL_BASE, ...
                 'MarkerFaceColor', COL_BASE, 'LineWidth', 1.1, 'CapSize', 5);
        errorbar(sessions(~isB), mu(~isB), sd(~isB), 'o', 'Color', COL_INT, ...
                 'MarkerFaceColor', COL_INT, 'LineWidth', 1.1, 'CapSize', 5);
        if isfinite(phM.(char(BASELINE_LABEL)))
            plot([min(baseSess)-0.3, max(baseSess)+0.3], ...
                 phM.(char(BASELINE_LABEL))*[1 1], '-', 'Color', COL_BASE, 'LineWidth', 2);
        end
        if isfinite(phM.(char(INTERV_LABEL)))
            plot([min(intSess)-0.3, max(intSess)+0.3], ...
                 phM.(char(INTERV_LABEL))*[1 1], '-', 'Color', COL_INT, 'LineWidth', 2);
        end
        xline(phaseLine, '--', 'AR starts', 'LabelVerticalAlignment','bottom', ...
              'Color', [0.4 0.4 0.4]);
        if isNorm, yline(1, ':', 'Color', [0.4 0.4 0.4]); end
        xlim([min(sessions)-0.6, max(sessions)+0.6]); xticks(sessions);
        xlabel('Session');
        ylabel(ternary(isNorm, 'normalised to baseline', lab));
        title(sprintf('%s - session mean \\pm SD (bar = phase mean)', legName));
        legend({'AFO (baseline)','AFO+AR'}, 'Location','southoutside', ...
               'Orientation','horizontal');

        % ---------- Panel B: Control / AR1 / AR2 / AR3 ----------
        nexttile; hold on; grid on; box on;
        xg = 1:numel(grp);
        errorbar(xg(1), gMu(1), gSd(1), 'o', 'Color', COL_BASE, ...
                 'MarkerFaceColor', COL_BASE, 'LineWidth', 1.1, 'CapSize', 6);
        errorbar(xg(2:end), gMu(2:end), gSd(2:end), 'o-', 'Color', COL_INT, ...
                 'MarkerFaceColor', COL_INT, 'LineWidth', 1.1, 'CapSize', 6);
        if isNorm, yline(1, ':', 'Color', [0.4 0.4 0.4]); end
        xlim([0.5, numel(grp)+0.5]); xticks(xg);
        xticklabels(compose('%s (n=%d)', grp', gN')');
        ylabel(ternary(isNorm, 'normalised to baseline', lab));
        title(sprintf('%s - baseline vs 1st/2nd/3rd AR walk', legName));
    end

    exportgraphics(fig, fullfile(figFolder, [col '.png']), 'Resolution', 150);
    close(fig);
    fprintf('%-26s -> FIG5\\%s.png\n', col, col);
end

% ===== tables =====
S = cell2table(sesRows, 'VariableNames', ...
      {'variable','leg','session','condition','n_trials','mean','sd','cv_pct'});
P = cell2table(phRows, 'VariableNames', ...
      {'variable','leg','phase','n_sessions','sessions','mean_of_session_means', ...
       'sd_of_session_means','cv_pct','slope_per_session'});
W = cell2table(wkRows, 'VariableNames', {'variable','leg','group','n','mean','sd'});
writetable(S, fullfile(resFolder, sprintf('INTERSESSION_%s.csv', participant)));
writetable(P, fullfile(resFolder, sprintf('PHASES_%s.csv', participant)));
writetable(W, fullfile(resFolder, sprintf('WALKORDER_%s.csv', participant)));
fprintf('\nSaved INTERSESSION_, PHASES_ and WALKORDER_%s.csv to %s\n', participant, resFolder);

% ===== console summary =====
fprintf('\n=== PHASES (on session means) ===\n');
fprintf('%-24s %-3s %-7s %3s %8s %8s %8s %9s\n', ...
        'variable','leg','phase','n','mean','sd','cv%','slope');
for col = ["pushForce_mean_norm","pushForce_ratio_norm","cadence_steps_min"]
    r = P(P.variable == col, :);
    for i = 1:height(r)
        fprintf('%-24s %-3s %-7s %3d %8.3f %8.3f %8.1f %9.4f\n', col, r.leg(i), ...
                r.phase(i), r.n_sessions(i), r.mean_of_session_means(i), ...
                r.sd_of_session_means(i), r.cv_pct(i), r.slope_per_session(i));
    end
end
fprintf('\n=== CONTROL / AR1 / AR2 / AR3 (headline variables) ===\n');
for col = ["pushForce_mean_norm","pushForce_ratio_norm","cadence_steps_min"]
    for lg = unique(W.leg(W.variable == col))'
        r = W(W.variable == col & W.leg == lg, :);
        fprintf('%-24s %s  %s\n', col, lg, ...
                strjoin(compose('%s=%.3f', r.group, r.mean)', '  '));
    end
end
b = P(P.phase == BASELINE_LABEL & endsWith(P.variable, "_norm"), :);
fprintf('\nBaseline phase mean of every normalised variable: %.6f to %.6f (must be 1).\n', ...
        min(b.mean_of_session_means), max(b.mean_of_session_means));

% ===== helpers =====
function out = ternary(c,a,b), if c, out = a; else, out = b; end, end

function s = joinNums(x, sep)
% Comma list of numbers; "" when there are none.
    if isempty(x), s = ""; else, s = strjoin(string(x(:)'), sep); end
end

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
