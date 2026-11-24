% s3f_GameMetrics.m
% =========================================================================
% STAGE 3.   AR game outcomes - protocol section 2, PRIMARY outcomes:
%            "game success rate, game threshold".
%
% WHAT THIS PROCESSES
%   RAW\AR game\vr_events_<P>_*.csv        one file per AR trial (game log)
%   RAW\inGAIT\InGait_<P>_*.csv            only to put the game on the trial clock
%   PROCESSED\TRIALMAP_<P>.csv             which trials are AFO_AR
%   PROCESSED\SYNC\SPATIOTEMPORAL_<P>.csv  the trial window (same as s2d/s2e)
%
% WHAT IT ACHIEVES
%   PROCESSED\RESULTS\GAME_<P>.csv           one row per AR trial per leg
%   PROCESSED\RESULTS\GAME_SESSIONS_<P>.csv  per session: mean, SD, CV, n
%   PROCESSED\RESULTS\GAME_PHASE_<P>.csv     AR phase: mean, SD, CV, slope of
%                                            the session means
%   PROCESSED\RESULTS\FIG_GAME\<metric>.png  trials per session + session mean
%   PROCESSED\RESULTS\FIG_GAME\check_trial<k>.png   alignment check
%
% REPLACES e_VR_section.m, which attached the game log to the sync file and
% plotted it, but computed no outcome and relied on a GaitUp time_sync field
% this pipeline does not have. The game shares the ROS clock with inGAIT, so
% no alignment is needed: t = (ros_timestamp - first inGAIT sample) * 1e-9.
% Game files are matched to trials by TIME OVERLAP, not by file number.
%
% ============ HOW THE GAME WORKS (verified on CP03's logs) ============
% Thresholds T are in raw forefoot-FSR counts: the force value of each step
% (rt_v) is an inGAIT forefoot sample, same signal and units as s2d's force.
% For each detected step k (RT event) of a leg, in this order:
%   1. the success rate of the last 4 steps is updated (step k counted as a
%      success if its force >= 1.10 x the threshold BEFORE this update) and
%      logged in the THRESHOLD message; then
%        <= 25 %  -> T x 0.97 ;   100 %  -> T x 1.03 ;   50-75 %  -> T kept,
%      except that T never rises above 1.40 x the value it started the trial at;
%   2. step k is scored against the NEW threshold and logged (RT event):
%        force < 1.10 T           -> Fail      (rabbit trips)
%        1.10 T <= force < 1.30 T -> LowJump   (successful jump)
%        force >= 1.30 T          -> HighJump  (higher jump + carrot)
% CP03 logs: scoring agrees on all 3253 steps; the staircase, with the 1.40
% ceiling, explains all 3157 threshold changes (13 were stopped by the
% ceiling: right leg, trials 20, 25, 26). The CEA paper says "last five
% steps"; the logs move in 25 % steps, i.e. four. The ceiling is not in the
% paper; it is inferred from the 13 blocked increases (every one would have
% passed 1.40 x start; no logged threshold exceeds 1.38 x start).
% The script re-checks the scoring and the staircase (direction, size and
% ceiling) on every run and prints the number of violations.
%
% WHAT THAT MEANS FOR THE TWO PROTOCOL OUTCOMES
%   SUCCESS RATE: the staircase pulls it back towards 50-75 % whenever it
%   leaves that band, so ~0.6 is expected in every session. It shows the game
%   worked as intended; it is not built to show improvement. It falls below
%   the band only when the threshold cannot follow (sensor failure, e.g.
%   trial 27 right, 0.36) and is held above it at the 1.40 ceiling.
%   THRESHOLD is what moves: the staircase carries it to the force the child
%   actually produces. That is the performance measure. But it is in raw FSR
%   counts and the operator sets its starting value for every trial, from
%   that session's insole (left starts at 85, 35, 202 ... in sessions 5-7 as
%   the insole failed and was replaced). So, exactly as for push-off force:
%     threshold_mean   raw counts, the protocol measure
%     threshold_rel    threshold_mean / threshold at the start of the trial:
%                      same insole, same fitting -> gain cancels. Above 1 =
%                      the child pushed beyond the level the game started at.
%                      It cannot exceed 1.40 (the game's ceiling).
%     threshold_gain   threshold at the end of the trial / at its start
%
% NO NAP / TAU-U HERE. The game runs only in AR sessions, so there is no
% baseline phase to compare against. These outcomes are reported as the
% protocol's sections 3.1 (every trial) and 3.2 (session means, SD, CV,
% trend) describe.
%
% DEFINITIONS
%   Steps counted: RT events whose time lies inside the trial window
%   [trialStart_s, windowEnd_s] from SPATIOTEMPORAL (identical to s2d/s2e).
%   Event time = ros_timestamp, the ROS time the step was LOGGED; it comes
%   0.2-1.7 s (median 0.5-0.8 s) after the force sample that was scored.
%   success_rate          (LowJump + HighJump) / steps: the outcomes the child
%                         saw. (The staircase's internal rate, step 1 above,
%                         differs from it by -4 to +3 points per trial-leg.)
%   success_rate_obstacle the same on obstacle steps only
%   high_jump_rate        HighJump / steps
%   threshold at a step   the threshold that step was scored against (the last
%                         threshold logged for that leg before it).
%   threshold_start       the threshold the operator set when the game was
%                         started for the trial: the first value in the log.
%                         When the recording began after the game had started
%                         (CP03 trials 14, 17, 23) the first message is already
%                         an update, and the value before it is recovered from
%                         the rule (decreased: /0.97, increased: /1.03, kept: =),
%                         exact to the log's 2-decimal rounding.
%
% NOTHING IS EXCLUDED. Known sensor faults (left insole sessions 4-6, right
% insole trial 27) also corrupt the game, which reads the same insole. They
% are in ISSUES_<P>.txt and the single sensitivity re-run handles them.
%
% RUNTIME: under a minute.
% =========================================================================

clear; clc; close all;

% ===== USER SETTINGS =====
participant = 'CP03';
Root        = 'C:\INVESTIGACION CSIC\PAC03';
gameFolder  = fullfile(Root,'RAW','AR game');            % <- folder with vr_events_*.csv
inGaitFolder= fullfile(Root,'RAW','inGAIT');
TrialMapCsv = fullfile(Root,'PROCESSED',sprintf('TRIALMAP_%s.csv',participant));
spatCsv     = fullfile(Root,'PROCESSED','SYNC',sprintf('SPATIOTEMPORAL_%s.csv',participant));
resFolder   = fullfile(Root,'PROCESSED','RESULTS');
figFolder   = fullfile(resFolder,'FIG_GAME');

INTERV_LABEL = "AFO_AR";
FAIL_MAX  = 1.10;      % game rule (checked, not used to score)
HIGH_MIN  = 1.30;
STEP      = 0.03;      % threshold staircase step
CAP       = 1.40;      % threshold never above CAP x its start value (inferred, see header)
COL_INT   = [0.90 0.50 0.10];
% =========================

for f = {gameFolder, inGaitFolder}
    if ~exist(f{1},'dir'), error('Folder not found:\n  %s', f{1}); end
end
for f = {TrialMapCsv, spatCsv}
    if ~isfile(f{1}), error('Not found:\n  %s', f{1}); end
end
if ~exist(figFolder,'dir'), mkdir(figFolder); end
old = dir(fullfile(figFolder, '*.png'));
for q = 1:numel(old), delete(fullfile(old(q).folder, old(q).name)); end

M  = loadMap(TrialMapCsv);
SP = readtable(spatCsv, 'TextType','string');
if ~ismember('windowEnd_s', SP.Properties.VariableNames)
    error('SPATIOTEMPORAL has no windowEnd_s - run s2e_SpatioTemporal.m (v6) first.');
end

% ---- time span of every game file ----
gf = dir(fullfile(gameFolder, 'vr_events_*.csv'));
if isempty(gf), error('No vr_events_*.csv in %s', gameFolder); end
gSpan = nan(numel(gf),2);
for j = 1:numel(gf)
    o = detectImportOptions(fullfile(gf(j).folder, gf(j).name));
    o.SelectedVariableNames = {'ros_timestamp'};
    g = readtable(fullfile(gf(j).folder, gf(j).name), o);
    gSpan(j,:) = [min(double(g.ros_timestamp)) max(double(g.ros_timestamp))];
end
used = zeros(numel(gf),1);

arTrials = M.trial(M.condition == INTERV_LABEL)';
fprintf('%d AR trials, %d game files in %s\n\n', numel(arTrials), numel(gf), gameFolder);
fprintf('%-3s %-3s %-2s %5s %6s %6s %6s %8s %8s %8s %7s %7s  %s\n', 'tr','S','lg', ...
        'steps','succ','succOb','high','thrInit','thrMean','thrEnd','thrRel','thrGain','file');
fprintf('%s\n', repmat('-',1,112));

rows = {}; nRuleBad = 0; nRuleChecked = 0; nStairBad = 0; nStairChecked = 0; nCap = 0;
checkTrial = NaN;
for k = arTrials
    i  = find(M.trial == k, 1);
    sess = M.session(i);
    igF = fullfile(inGaitFolder, char(M.inGAIT_file(i)));
    if ~isfile(igF), fprintf('%-3d inGAIT file missing - no clock\n', k); continue; end
    IG  = readtable(igF, 'Delimiter', ',', 'TextType', 'string');
    ros = double(IG.ros_timestamp);
    i0  = ros(1);

    % game file = the one overlapping this trial most
    ov = min(gSpan(:,2), ros(end)) - max(gSpan(:,1), ros(1));
    [best, j] = max(ov);
    if best <= 0
        fprintf('%-3d %-3d   no game file overlaps this trial\n', k, sess);
        rows(end+1,:) = emptyRow(k, sess, "L"); rows(end+1,:) = emptyRow(k, sess, "R"); %#ok<AGROW>
        continue;
    end
    if used(j) > 0
        error('Game file %s overlaps both trial %d and trial %d.', gf(j).name, used(j), k);
    end
    used(j) = k;

    w = find(SP.trial == k, 1);
    if isempty(w), error('Trial %d is not in SPATIOTEMPORAL.', k); end
    b1 = SP.trialStart_s(w); b2 = SP.windowEnd_s(w);

    E = readtable(fullfile(gf(j).folder, gf(j).name), 'TextType','string', 'Delimiter', ',');
    E = sortrows(E, 'ros_timestamp');              % stable for ties
    E.t = (double(E.ros_timestamp) - i0)*1e-9;
    if isnan(checkTrial), checkTrial = k; checkE = E; checkIG = IG; checkWin = [b1 b2]; end

    for lgName = ["Left","Right"]
        lg = extractBefore(lgName, 2);
        L  = E(E.leg == lgName, :);
        isTH = L.event == "THRESHOLD";
        isRT = L.event == "RT";
        thrVal = nan(height(L),1); kinds = strings(height(L),1); srv = nan(height(L),1);
        for q = find(isTH)'
            [kinds(q), thrVal(q), srv(q)] = parseThr(L.msg(q));
        end
        ith = find(isTH & isfinite(thrVal));
        if isempty(ith) || ~any(isRT)
            rows(end+1,:) = emptyRow(k, sess, lg); %#ok<AGROW>
            fprintf('%-3d %-3d %-2s   no steps or no threshold in the log\n', k, sess, lg);
            continue;
        end

        % threshold in force before the first logged message
        f0 = ith(1);
        if isnan(srv(f0)) || kinds(f0) == "updated"
            prior = thrVal(f0);
        elseif kinds(f0) == "decreased"
            prior = thrVal(f0)/(1 - STEP);
        else
            prior = thrVal(f0)/(1 + STEP);
        end
        thrAt = nan(height(L),1); cur = prior;
        for q = 1:height(L)
            if isTH(q) && isfinite(thrVal(q)), cur = thrVal(q); end
            thrAt(q) = cur;
        end

        % ---- rule checks: staircase direction, size and ceiling ----
        seq = thrVal(ith); srs = srv(ith);
        for q = 2:numel(seq)
            if isnan(srs(q)), continue; end         % a fresh setting by the operator
            if srs(q) <= 25
                expR = 1 - STEP;
            elseif srs(q) >= 100
                expR = 1 + STEP;
                if seq(q-1)*(1 + STEP) > CAP*prior + 1e-6, expR = 1; nCap = nCap + 1; end
            else
                expR = 1;
            end
            nStairChecked = nStairChecked + 1;
            if abs(seq(q)/seq(q-1) - expR) > 1e-3, nStairBad = nStairBad + 1; end
        end

        R  = isRT & L.t >= b1 & L.t <= b2;
        st = L.step_type(R);
        ratio = L.rt_v(R) ./ thrAt(R);
        expd  = repmat("HighJump", nnz(R), 1);
        expd(ratio < HIGH_MIN) = "LowJump";
        expd(ratio < FAIL_MAX) = "Fail";
        nearB = abs(ratio - FAIL_MAX) < 1e-3 | abs(ratio - HIGH_MIN) < 1e-3 | ~isfinite(ratio);
        nRuleBad = nRuleBad + nnz(expd ~= st & ~nearB);
        nRuleChecked = nRuleChecked + nnz(~nearB);

        % ---- metrics ----
        nS    = nnz(R);
        succ  = st == "LowJump" | st == "HighJump";
        ob    = L.obstacle(R) == 1;
        srAll = mean(succ);
        srOb  = NaN; if any(ob), srOb = mean(succ(ob)); end
        hiR   = mean(st == "HighJump");
        tr    = thrAt(R);
        thrMean = mean(tr, 'omitnan');
        lastTH  = find(isTH & isfinite(thrVal) & L.t <= b2, 1, 'last');
        thrEnd  = prior; if ~isempty(lastTH), thrEnd = thrVal(lastTH); end
        rows(end+1,:) = {k, sess, lg, nS, nnz(ob), nnz(isRT) - nS, srAll, srOb, hiR, ...
                         prior, thrMean, thrEnd, thrMean/prior, thrEnd/prior, ...
                         string(gf(j).name)}; %#ok<AGROW>
        fprintf('%-3d %-3d %-2s %5d %6.3f %6.3f %6.3f %8.2f %8.2f %8.2f %7.3f %7.3f  %s\n', ...
                k, sess, lg, nS, srAll, srOb, hiR, prior, thrMean, thrEnd, thrMean/prior, ...
                thrEnd/prior, gf(j).name);
    end
end
if any(used == 0)
    fprintf('\nGame file(s) matched to no AR trial: %s\n', strjoin(string({gf(used==0).name}), ', '));
end

G = cell2table(rows, 'VariableNames', {'trial','session','leg','n_steps','n_obstacle', ...
      'n_outside_window','success_rate','success_rate_obstacle','high_jump_rate', ...
      'threshold_start','threshold_mean','threshold_end','threshold_rel','threshold_gain', ...
      'game_file'});
writetable(G, fullfile(resFolder, sprintf('GAME_%s.csv', participant)));

% ===== session and phase statistics (as s3c: on session means) =====
METRICS = {
  'success_rate',   'Game success rate (share of steps that jumped)', 0
  'threshold_mean', 'Game threshold (raw FSR counts)',                0
  'threshold_rel',  'Game threshold relative to its start in the trial', 1
  'threshold_gain', 'Game threshold at end / at start of the trial',   1
  };
sesRows = {}; phRows = {};
G.walk = zeros(height(G),1);
for s = unique(G.session)'
    tr = unique(G.trial(G.session == s));
    for q = 1:numel(tr), G.walk(G.trial == tr(q)) = q; end
end
for v = 1:size(METRICS,1)
    col = METRICS{v,1};
    for lg = ["L","R"]
        m = G.leg == lg;
        ss = unique(G.session(m))';
        mu = nan(size(ss)); sdv = mu; nn = zeros(size(ss));
        for q = 1:numel(ss)
            y = G.(col)(m & G.session == ss(q)); y = y(isfinite(y));
            nn(q) = numel(y);
            if nn(q) >= 1, mu(q) = mean(y); end
            if nn(q) >= 2, sdv(q) = std(y); end
            sesRows(end+1,:) = {string(col), lg, ss(q), nn(q), mu(q), sdv(q), ...
                                100*sdv(q)/abs(mu(q))}; %#ok<AGROW>
        end
        ok = isfinite(mu);
        pm = NaN; psd = NaN; pcv = NaN; slope = NaN;
        if any(ok), pm = mean(mu(ok)); end
        if nnz(ok) >= 2
            psd = std(mu(ok)); pcv = 100*psd/abs(pm);
            pf = polyfit(ss(ok), mu(ok), 1); slope = pf(1);
        end
        phRows(end+1,:) = {string(col), lg, nnz(ok), pm, psd, pcv, slope}; %#ok<AGROW>
    end
end
SS = cell2table(sesRows, 'VariableNames', {'variable','leg','session','n_trials','mean','sd','cv_pct'});
PH = cell2table(phRows,  'VariableNames', {'variable','leg','n_sessions','mean_of_session_means', ...
                                           'sd_of_session_means','cv_pct','slope_per_session'});
writetable(SS, fullfile(resFolder, sprintf('GAME_SESSIONS_%s.csv', participant)));
writetable(PH, fullfile(resFolder, sprintf('GAME_PHASE_%s.csv', participant)));

% ===== figures: every trial + session mean +/- SD =====
for v = 1:3                                   % threshold_gain is in the tables only
    col = METRICS{v,1}; lab = METRICS{v,2}; isRel = METRICS{v,3};
    fig = figure('Color','w','Visible','off','Position',[100 100 1300 470]);
    tl  = tiledlayout(1, 2, 'TileSpacing','compact');
    title(tl, sprintf('%s - %s (AR sessions only)', lab, participant), 'FontWeight','bold');
    for lg = ["L","R"]
        nexttile; hold on; grid on; box on;
        m = G.leg == lg & isfinite(G.(col));
        hList = gobjects(0); lList = {};
        if strcmp(col, 'success_rate')
            hList(end+1) = patch([4.4 10.6 10.6 4.4], [0.5 0.5 0.75 0.75], [0.6 0.6 0.6], ...
                                 'FaceAlpha', 0.15, 'EdgeColor', 'none'); %#ok<AGROW>
            lList{end+1} = 'staircase hold zone (50-75 %)'; %#ok<AGROW>
        end
        hList(end+1) = scatter(G.session(m) + (G.walk(m)-2)*0.15, G.(col)(m), 36, COL_INT, ...
                               'filled', 'MarkerFaceAlpha', 0.85); %#ok<AGROW>
        lList{end+1} = 'trial'; %#ok<AGROW>
        r = SS(SS.variable == string(col) & SS.leg == lg, :);
        hList(end+1) = errorbar(r.session, r.mean, r.sd, 'ks-', 'MarkerFaceColor','w', ...
                                'LineWidth', 1.3, 'CapSize', 5); %#ok<AGROW>
        lList{end+1} = 'session mean \pm SD'; %#ok<AGROW>
        if isRel, yline(1, ':', 'start of trial', 'Color', [0.4 0.4 0.4]); end
        xlim([4.4 10.6]); xticks(5:10); xlabel('Session');
        ylabel(lab);
        title(sprintf('%s leg', ternary(lg == "L", 'Left', 'Right')));
        legend(hList, lList, 'Location','southoutside', 'Orientation','horizontal');
    end
    exportgraphics(fig, fullfile(figFolder, [col '.png']), 'Resolution', 150);
    close(fig);
    fprintf('%-16s -> FIG_GAME\\%s.png\n', col, col);
end

% ===== alignment check: game steps on top of the inGAIT forefoot FSR =====
if ~isnan(checkTrial)
    fig = figure('Color','w','Visible','off','Position',[100 100 1300 650]);
    tl  = tiledlayout(2, 1, 'TileSpacing','compact');
    title(tl, sprintf(['Trial %d - inGAIT forefoot FSR (line) and game steps (markers, ' ...
                       'plotted at their ROS log time) - first 20 s of the window'], checkTrial));
    tIG = (double(checkIG.ros_timestamp) - double(checkIG.ros_timestamp(1)))*1e-9;
    for lgName = ["Left","Right"]
        nexttile; hold on; grid on; box on;
        fcol = ['force_' lower(char(extractBefore(lgName,2)))];
        w = tIG >= checkWin(1) & tIG <= checkWin(1) + 20;
        plot(tIG(w), double(checkIG.(fcol)(w)), 'Color', [0.3 0.3 0.3]);
        L = checkE(checkE.leg == lgName & checkE.event == "RT" & ...
                   checkE.t >= checkWin(1) & checkE.t <= checkWin(1) + 20, :);
        cls = ["Fail","LowJump","HighJump"]; cc = [0.85 0.2 0.2; 0.95 0.65 0.1; 0.2 0.65 0.3];
        for c = 1:3
            mm = L.step_type == cls(c);
            scatter(L.t(mm), L.rt_v(mm), 40, cc(c,:), 'filled');
        end
        xlabel('trial time [s]'); ylabel('forefoot FSR [counts]');
        title(sprintf('%s: red Fail, amber LowJump, green HighJump', lgName));
    end
    exportgraphics(fig, fullfile(figFolder, sprintf('check_trial%d.png', checkTrial)), 'Resolution', 130);
    close(fig);
end

% ===== console summary =====
fprintf('\nSaved GAME_, GAME_SESSIONS_ and GAME_PHASE_%s.csv to %s\n', participant, resFolder);
fprintf('\n=== GAME RULE CHECKS ===\n');
fprintf('Step scoring (Fail < %.2f T <= LowJump < %.2f T <= HighJump): %d of %d steps disagree.\n', ...
        FAIL_MAX, HIGH_MIN, nRuleBad, nRuleChecked);
fprintf(['Threshold changes that break the staircase (<=25 %%: x%.2f, 100 %%: x%.2f up to\n' ...
         '%.2f x start, otherwise x1): %d of %d. Increases stopped by the ceiling: %d.\n'], ...
        1-STEP, 1+STEP, CAP, nStairBad, nStairChecked, nCap);
if nRuleBad > 0 || nStairBad > 0
    fprintf(['   Non-zero means the game version or its log changed - the definitions in\n' ...
             '   the header must be re-checked before these outcomes are reported.\n']);
end
fprintf('\n=== AR PHASE (on session means) ===\n');
fprintf('%-16s %-3s %3s %9s %9s %7s %9s\n','variable','leg','n','mean','sd','cv%','slope');
for q = 1:height(PH)
    fprintf('%-16s %-3s %3d %9.3f %9.3f %7.1f %9.4f\n', PH.variable(q), PH.leg(q), ...
            PH.n_sessions(q), PH.mean_of_session_means(q), PH.sd_of_session_means(q), ...
            PH.cv_pct(q), PH.slope_per_session(q));
end
fprintf(['\nSuccess rate is pulled back to 50-75 %% by the game''s staircase, so ~0.6 in\n' ...
         'every session is expected. The threshold is the performance measure;\n' ...
         'threshold_rel and threshold_gain are its gain-free forms (ceiling %.2f).\n' ...
         'No NAP/Tau-U: the game has no baseline phase.\n'], CAP);

% ===== helpers =====
function [kind, val, sr] = parseThr(msg)
% "Left threshold decreased to 82.45. Success rate: 0 %" -> "decreased", 82.45, 0
    kind = ""; val = NaN; sr = NaN;
    tok = regexp(char(msg), ['threshold\s+(updated|decreased|increased)\s+to\s+' ...
                 '(-?\d+(?:\.\d+)?)\.?\s*Success rate:\s*(NaN|-?\d+(?:\.\d+)?)'], 'tokens', 'once');
    if isempty(tok), return; end
    kind = string(tok{1}); val = str2double(tok{2}); sr = str2double(tok{3});
end

function r = emptyRow(k, s, lg)
    r = {k, s, string(lg), 0, 0, 0, NaN, NaN, NaN, NaN, NaN, NaN, NaN, NaN, ""};
end

function out = ternary(c,a,b), if c, out = a; else, out = b; end, end

function M = loadMap(csvPath)
    opts = detectImportOptions(csvPath,'TextType','string');
    txt  = intersect({'date','condition','inGAIT_file','EMG_file','IMU_file', ...
                      'gaitup_day','gaitup_LF','gaitup_RF','notes'}, opts.VariableNames);
    if ~isempty(txt), opts = setvartype(opts, txt, 'string'); end
    num  = intersect({'trial','session'}, opts.VariableNames);
    if ~isempty(num), opts = setvartype(opts, num, 'double'); end
    M = readtable(csvPath, opts);
end
