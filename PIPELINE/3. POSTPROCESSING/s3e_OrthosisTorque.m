% s3e_OrthosisTorque.m
% =========================================================================
% STAGE 3.   Orthosis (inGAIT-VSO) torque at the child's maximum dorsiflexion.
%            Adapts the lab's torqueCalculationLoss.m to this pipeline.
%            DESCRIPTIVE: torque is not an outcome in protocol section 2; it
%            documents how much assistance the orthosis actually gave.
%
% WHAT THIS PROCESSES
%   <Data analysis>\3. Postprocessing\slider_position\Extras\
%       ExperimentalCharacterization.fig   11 loading curves, torque vs angle
%       unloadingDorsi.mat                 the 11 matching unloading curves
%   PROCESSED\SYNC\<P>_trial<k>_sync.mat    right ankle angle + native shank gyro
%   PROCESSED\SYNC\SPATIOTEMPORAL_<P>.csv   trial window and ankle ROM (s2e v6)
%   PROCESSED\TRIALMAP_<P>.csv
%
% WHAT IT ACHIEVES
%   PROCESSED\RESULTS\TORQUE_<P>.csv            one row per trial (orthosis leg)
%   PROCESSED\RESULTS\TORQUE_SESSIONS_<P>.csv   per session: mean, SD, CV, n
%   PROCESSED\RESULTS\TORQUE_PHASE_<P>.csv      per phase: mean, SD, CV, slope
%   PROCESSED\RESULTS\FIG_TORQUE\characterization.png   curves + operating points
%   PROCESSED\RESULTS\FIG_TORQUE\sessions.png           max DF and torque per session
%
% ============ THE ORTHOSIS SETTING, AND WHAT THE SHEET'S 0.05 IS ============
% The participant sheet lists, per child, a mass, a "Torque (Nm/kg)" value and
% a slider position. For CP01-CP03 those are 0.13384 / 68.1 mm, 0.19264 /
% 76.05 mm and 0.05 / 43.4 mm. Read with the characterization curves:
%   - the "Torque (Nm/kg)" column is the TORQUE COEFFICIENT AT 89 mm that
%     InterpolateSliderPosition_NEW.m prints ("The torque coefficient at 89mm
%     for this subject is ..."): the softest setting the device can reach for
%     that child. Its formula reproduces all three values to 5 decimals
%     (0.13384, 0.19264, 0.05019). It is NOT the prescribed coefficient.
%   - a prescription of 0.40 Nm/kg at 12 deg reproduces all three slider
%     positions (68.11, 76.05, 43.35 mm against 68.1, 76.05, 43.4).
% So the slider is consistent with the curves, and it is the physical setting
% actually used. This script therefore starts from the SLIDER:
%   torque at 12 deg = linear interpolation of the 11 curves' torque at 12 deg
%                      across slider position (the inverse of the lab's own
%                      interp1), CP03: 43.4 mm -> 30.36 Nm = 0.3995 Nm/kg,
% and feeds that coefficient to the lab's algorithm. The sheet's 0.05 is used
% only as a CHECK: the script recomputes the 89-mm coefficient for MASS_KG and
% stops if it does not match SHEET_COEF89. That check also proves the curves
% are read in the order the lab code assumes (curve 1 = 32.5 mm).
% ==========================================================================
%
% THE LAB'S ALGORITHM (torqueCalculationLoss.m), reproduced exactly
%   - each curve's torque at an angle = the sample whose angle is closest to it
%     (first one if tied; a sample at distance exactly 0 is skipped, as in the
%     lab code, which used 0 as padding);
%   - the two curves whose torque at 12 deg brackets the target, and the
%     fraction 'ratio' between them, are fixed once from the 12-deg target;
%   - torque at any angle = curve(first) - ratio*(curve(first) - curve(second)),
%     on the loading curves and, with the lab's reversed indexing (12 - idx),
%     on the unloading curves. Loading and unloading differ by the spring's
%     hysteresis; both are reported.
%   If the lab rule ever picks two curves that do NOT bracket the target (it
%   can, for some spacings, and would then extrapolate), the curves either side
%   of the slider are used instead and the console says so. Not the case for
%   CP03 (curves 2 and 3, ratio 0.929).
% Read in the lab's order, curve 1 = 32.5 mm is the STIFFEST setting and
% curve 11 = 88.4 mm the softest (39.8 and 4.8 Nm at 12 deg).
% Self-test: the interpolated loading torque at 12 deg must equal the target.
%
% MAXIMUM DORSIFLEXION (the lab's maxDors)
%   Per stride, the largest right ankle angle (dorsiflexion positive; the heel
%   downs are troughs). Strides are EXACTLY s2e v6's: consecutive mid-swing
%   peaks of the native right shank gyro inside the trial window, with the
%   same goniometer rules (trial not reportable if stuck, p5-p95 < 1 deg, or
%   wrapping, > 5% beyond +/-60 deg; a stride dropped if any sample is beyond
%   +/-60 deg or its range exceeds 90 deg; at least 10 strides). The script
%   recomputes the ankle ROM from the same strides and stops unless it equals
%   s2e's ankleROM_deg - proof the strides are identical.
%   Torque is computed per stride and then averaged over the trial.
%
% THE ENCODER ZERO
%   The ankle encoder is set to 0 deg at the start of each session; it may be
%   slightly off, and the raw angle is used as recorded (investigator's
%   decision). Be aware of the sensitivity: around CP03's operating range the
%   interpolated curve rises ~2.3 Nm per degree, so a 1 deg zero error moves
%   the torque by ~2.3 Nm (25-50 % of a typical value). Differences between
%   sessions therefore include each session's zeroing; read them with that in
%   mind. Within a session the zero is fixed.
%
% NOTHING IS EXCLUDED. Trials without a usable goniometer have no torque.
%
% RUNTIME: ~2-4 minutes.
% =========================================================================

clear; clc; close all;

% ===== USER SETTINGS =====
participant = 'CP03';
Root        = 'C:\INVESTIGACION CSIC\PAC03';
charFolder  = 'C:\INVESTIGACION CSIC\Data analysis\3. Postprocessing\slider_position\Extras';
postFolder  = fullfile(Root,'PROCESSED','SYNC');
TrialMapCsv = fullfile(Root,'PROCESSED',sprintf('TRIALMAP_%s.csv',participant));
spatCsv     = fullfile(postFolder, sprintf('SPATIOTEMPORAL_%s.csv', participant));
resFolder   = fullfile(Root,'PROCESSED','RESULTS');
figFolder   = fullfile(resFolder,'FIG_TORQUE');

% Orthosis settings from the participant sheet
MASS_KG      = 76;      % kg
SLIDER_MM    = 43.4;    % slider position used in the sessions
SHEET_COEF89 = 0.05;    % the sheet's "Torque (Nm/kg)" value - a CHECK only (see header)
COEF89_TOL   = 0.005;   % the sheet rounds it; CP03's exact value is 0.0502

% Lab constants (torqueCalculationLoss.m / InterpolateSliderPosition_NEW.m)
DF_REF      = 12;                                          % deg
SLIDER_PERC = [0 0.10 0.20 0.30 0.40 0.50 0.60 0.70 0.80 0.90 0.99];
SLIDER_MIN  = 32.5;  SLIDER_MAX = 89;                      % mm

% Stride and goniometer rules - IDENTICAL to s2e v6
FS_U = 100; MIN_STRIDE = 0.50; MAX_STRIDE = 2.50; MIN_EVENTS = 10; PEAK_SEP = 0.70;
ROM_MAX = 90; PHYS_ANGLE = 60; WRAP_MAX = 5; FLAT_RANGE = 1.0;
gonioSide = 'r';
EPS_T = 1e-9;   % s; the window edges come back from a CSV - keep s2e's edge samples

BASELINE_LABEL = "AFO"; INTERV_LABEL = "AFO_AR";
COL_BASE = [0.20 0.45 0.75]; COL_INT = [0.90 0.50 0.10];
% =========================

figF = fullfile(charFolder, 'ExperimentalCharacterization.fig');
matF = fullfile(charFolder, 'unloadingDorsi.mat');
for f = {figF, matF, TrialMapCsv, spatCsv}
    if ~isfile(f{1}), error('Not found:\n  %s', f{1}); end
end
if ~exist(figFolder,'dir'), mkdir(figFolder); end
old = dir(fullfile(figFolder, '*.png'));
for q = 1:numel(old), delete(fullfile(old(q).folder, old(q).name)); end

% ===== characterization curves, read exactly as the lab code reads them =====
hf = openfig(figF, 'invisible');
ax = hf.CurrentAxes;                               % the lab code used gca
if isempty(ax), ax = findobj(hf, 'Type', 'axes'); ax = ax(1); end
ch = get(ax, 'Children');                          % same order as get(gca,'Children')
ch = ch(strcmp(get(ch, 'Type'), 'line'));
LX = cell(numel(ch),1); LY = LX;
for i = 1:numel(ch)
    LX{i} = double(get(ch(i), 'XData')); LX{i} = LX{i}(:);
    LY{i} = double(get(ch(i), 'YData')); LY{i} = LY{i}(:);
end
close(hf);
S0 = load(matF, 'unloadingDorsi'); U = S0.unloadingDorsi;
if numel(LX) ~= 11 || numel(U) ~= 11
    error('Expected 11 loading and 11 unloading curves; found %d and %d.', numel(LX), numel(U));
end
UX = cell(11,1); UY = UX;
for i = 1:11, UX{i} = double(U{i}(:,1)); UY{i} = double(U{i}(:,2)); end

% check 1: unloading curve 12-k belongs to loading curve k (the lab's indexing):
% of all unloading curves, 12-k is the one whose peak is closest to curve k's.
mL = cellfun(@max, LY); mU = cellfun(@max, UY);
for k = 1:11
    [~, jj] = min(abs(mU - mL(k)));
    if jj ~= 12 - k
        error(['Unloading curve %d pairs with loading curve %d, not %d as the lab code ' ...
               'assumes. The curve files are not the ones the lab code was written for.'], ...
              jj, k, 12 - k);
    end
end

sliderPos = (SLIDER_MAX - SLIDER_MIN).*SLIDER_PERC + SLIDER_MIN;
y12 = zeros(11,1);
for i = 1:11, y12(i) = closestY(LX{i}, LY{i}, DF_REF); end

% check 2: the lab's coefficient at 89 mm must reproduce the sheet value
slope89 = (y12(11) - y12(10))/(sliderPos(10) - sliderPos(9));   % lab formula, as written
yat89   = y12(11) + (89 - sliderPos(10))*slope89;
coef89  = yat89/MASS_KG;
fprintf('Check: torque coefficient at 89 mm for %g kg = %.5f Nm/kg (sheet: %g)\n', ...
        MASS_KG, coef89, SHEET_COEF89);
if abs(coef89 - SHEET_COEF89) > COEF89_TOL
    error(['The 89-mm coefficient does not match the sheet. Either MASS_KG or ' ...
           'SHEET_COEF89 is wrong, or the curves are read in a different order.']);
end

% the setting: slider -> torque at 12 deg -> coefficient
if SLIDER_MM < min(sliderPos) || SLIDER_MM > max(sliderPos)
    error('SLIDER_MM = %g is outside the characterized range %.2f-%.2f mm.', ...
          SLIDER_MM, min(sliderPos), max(sliderPos));
end
T12  = interp1(sliderPos, y12, SLIDER_MM, 'linear');
coef = T12/MASS_KG;

% the lab's bracketing (torqueCalculationLoss.m, unchanged)
d2 = abs(y12 - T12);
[~, cl] = min(d2);
if cl == 11
    firstIdx = 10; secondIdx = 11;
elseif cl == 1
    firstIdx = 1;  secondIdx = 2;
elseif d2(cl+1) < d2(cl-1)
    firstIdx = cl; secondIdx = cl + 1;
else
    firstIdx = cl - 1; secondIdx = cl;
end
ratio = (y12(firstIdx) - T12)/(y12(firstIdx) - y12(secondIdx));
if ratio < 0 || ratio > 1
    % The lab rule picked two curves that do not bracket the target (it would
    % extrapolate at every angle but 12 deg). Use the curves either side of the
    % slider instead; the target at 12 deg is unchanged.
    jb = find(sliderPos <= SLIDER_MM, 1, 'last'); jb = min(jb, 10);
    fprintf(['NOTE: the lab bracket (%d,%d) extrapolates (ratio %.3f); using the ' ...
             'curves either side of the slider (%d,%d).\n'], firstIdx, secondIdx, ratio, jb, jb+1);
    firstIdx = jb; secondIdx = jb + 1;
    ratio = (y12(firstIdx) - T12)/(y12(firstIdx) - y12(secondIdx));
end
CV.LX = LX; CV.LY = LY; CV.UX = UX; CV.UY = UY;
CV.f = firstIdx; CV.s = secondIdx; CV.ratio = ratio;

% check 3: the interpolated curve passes through the target at 12 deg
[tq12, ~] = labTorque(CV, DF_REF);
if abs(tq12 - T12) > 1e-6
    error('Self-test failed: interpolated torque at 12 deg %.4f ~= target %.4f.', tq12, T12);
end
fprintf(['Slider %.1f mm -> %.2f Nm at %d deg -> %.4f Nm/kg  (curves %d and %d, ' ...
         'ratio %.3f). Self-tests passed.\n\n'], SLIDER_MM, T12, DF_REF, coef, ...
         firstIdx, secondIdx, ratio);

% ===== per trial: strides, max dorsiflexion, torque =====
M  = loadMap(TrialMapCsv);
SP = readtable(spatCsv, 'TextType','string');
if ~ismember('windowEnd_s', SP.Properties.VariableNames)
    error('SPATIOTEMPORAL has no windowEnd_s - run s2e_SpatioTemporal.m (v6) first.');
end
fprintf('%-3s %-3s %-7s %5s %8s %7s %9s %8s %9s %8s  %s\n', 'tr','S','cond','nStr', ...
        'maxDF','sd','torque','sd','unload','Nm/kg','note');
fprintf('%s\n', repmat('-',1,96));
rows = {}; nCross = 0; nOut = 0;
xRange = [max(min(LX{firstIdx}), min(LX{secondIdx})), min(max(LX{firstIdx}), max(LX{secondIdx}))];
for i = 1:height(M)
    k = M.trial(i); sess = M.session(i); cond = string(char(M.condition(i)));
    note = "";
    f = fullfile(postFolder, sprintf('%s_trial%d_sync.mat', participant, k));
    w = find(SP.trial == k & SP.isRight == double(gonioSide == 'r'), 1);
    if ~isfile(f) || isempty(w)
        rows(end+1,:) = {k, sess, cond, 0, NaN, NaN, NaN, NaN, NaN, NaN, "no sync file or no s2e row"}; %#ok<AGROW>
        continue;
    end
    S = load(f); A = S.inGAIT_All;
    if ~isfield(A, 'IMU_native')
        error('%s has no IMU_native - run s2c_Bundle.m (v2) first.', f);
    end
    b1 = SP.trialStart_s(w); b2 = SP.windowEnd_s(w);
    t  = double(A.inGAIT.time_sec);
    tu = (t(1):1/FS_U:t(end))';
    inb = tu >= b1 - EPS_T & tu <= b2 + EPS_T;
    ang  = double(A.inGAIT.(['angle_' gonioSide]));
    angb = ang(t >= b1 - EPS_T & t <= b2 + EPS_T);
    wrapPct   = 100*mean(abs(angb) > PHYS_ANGLE);
    robustRng = prctile(angb,95) - prctile(angb,5);

    mdf = []; rom = [];
    if robustRng < FLAT_RANGE
        note = "goniometer stuck";
    elseif wrapPct > WRAP_MAX
        note = sprintf("goniometer wrapping (%.0f%%)", wrapPct);
    else
        tn   = double(A.IMU_native.time_sec);
        magU = toUniform(tn, double(A.IMU_native.(sprintf('%s_mag', upper(gonioSide)))), tu);
        [~, evT] = stridesFrom(magU, tu, inb, FS_U, PEAK_SEP, MIN_STRIDE, MAX_STRIDE, MIN_EVENTS);
        for c = 1:numel(evT)-1
            ww = t >= evT(c) & t < evT(c+1);
            if nnz(ww) > 5
                aw = ang(ww);
                if any(abs(aw) > PHYS_ANGLE), continue; end
                rr = max(aw) - min(aw);
                if rr <= ROM_MAX, rom(end+1) = rr; mdf(end+1) = max(aw); end %#ok<AGROW>
            end
        end
        if numel(rom) < MIN_EVENTS
            note = sprintf("only %d clean strides", numel(rom)); mdf = []; rom = [];
        end
    end

    % cross-check against s2e: same strides -> same ROM
    romS2e = SP.ankleROM_deg(w);
    romHere = NaN; if ~isempty(rom), romHere = mean(rom); end
    if isfinite(romS2e) || isfinite(romHere)
        if ~(isfinite(romS2e) && isfinite(romHere) && abs(romS2e - romHere) < 1e-6)
            error(['Trial %d: ankle ROM %.6f here vs %.6f in s2e - the strides differ. ' ...
                   'Re-run s2e_SpatioTemporal.m (v6) and this script with the same bundle.'], ...
                  k, romHere, romS2e);
        end
        nCross = nCross + 1;
    end

    if isempty(mdf)
        rows(end+1,:) = {k, sess, cond, 0, NaN, NaN, NaN, NaN, NaN, NaN, note}; %#ok<AGROW>
        fprintf('%-3d %-3d %-7s %5d %8s %7s %9s %8s %9s %8s  %s\n', k, sess, cond, 0, ...
                '-', '-', '-', '-', '-', '-', note);
        continue;
    end
    tl = zeros(numel(mdf),1); tu2 = tl;
    for c = 1:numel(mdf), [tl(c), tu2(c)] = labTorque(CV, mdf(c)); end
    nOut = nOut + nnz(mdf < xRange(1) | mdf > xRange(2));
    rows(end+1,:) = {k, sess, cond, numel(mdf), mean(mdf), std(mdf), mean(tl), std(tl), ...
                     mean(tu2), mean(tl)/MASS_KG, note}; %#ok<AGROW>
    fprintf('%-3d %-3d %-7s %5d %8.2f %7.2f %9.2f %8.2f %9.2f %8.3f  %s\n', k, sess, cond, ...
            numel(mdf), mean(mdf), std(mdf), mean(tl), std(tl), mean(tu2), mean(tl)/MASS_KG, note);
end

T = cell2table(rows, 'VariableNames', {'trial','session','condition','n_strides', ...
      'maxDF_deg','maxDF_sd','torque_loading_Nm','torque_loading_sd', ...
      'torque_unloading_Nm','torque_loading_Nm_per_kg','note'});
writetable(T, fullfile(resFolder, sprintf('TORQUE_%s.csv', participant)));

% ===== session and phase statistics (on session means, as s3c) =====
VARS = {'maxDF_deg', 'Maximum dorsiflexion per stride (deg)'
        'torque_loading_Nm', 'Orthosis torque at max dorsiflexion (Nm)'};
intSess  = unique(T.session(T.condition == INTERV_LABEL))';
baseSess = setdiff(unique(T.session(T.condition == BASELINE_LABEL))', intSess);
inPhase  = (T.condition == BASELINE_LABEL & ismember(T.session, baseSess)) | ...
           (T.condition == INTERV_LABEL   & ismember(T.session, intSess));
sesRows = {}; phRows = {};
for v = 1:size(VARS,1)
    col = VARS{v,1};
    for s = unique(T.session)'
        y = T.(col)(T.session == s & inPhase); y = y(isfinite(y));
        mu = NaN; sdv = NaN;
        if ~isempty(y), mu = mean(y); end
        if numel(y) >= 2, sdv = std(y); end
        sesRows(end+1,:) = {string(col), s, ternary(ismember(s, baseSess), BASELINE_LABEL, ...
                            INTERV_LABEL), numel(y), mu, sdv, 100*sdv/abs(mu)}; %#ok<AGROW>
    end
    for ph = [BASELINE_LABEL, INTERV_LABEL]
        pS = ternary(ph == BASELINE_LABEL, baseSess, intSess);
        r  = sesRows(strcmp(cellfun(@char, sesRows(:,1), 'uni', 0), col), :);
        x = []; y = [];
        for q = 1:size(r,1)
            if ismember(r{q,2}, pS) && isfinite(r{q,5}), x(end+1) = r{q,2}; y(end+1) = r{q,5}; end %#ok<AGROW>
        end
        pm = NaN; psd = NaN; pcv = NaN; sl = NaN;
        if ~isempty(y), pm = mean(y); end
        if numel(y) >= 2, psd = std(y); pcv = 100*psd/abs(pm); pf = polyfit(x, y, 1); sl = pf(1); end
        phRows(end+1,:) = {string(col), ph, numel(y), pm, psd, pcv, sl}; %#ok<AGROW>
    end
end
SS = cell2table(sesRows, 'VariableNames', {'variable','session','condition','n_trials','mean','sd','cv_pct'});
PH = cell2table(phRows,  'VariableNames', {'variable','phase','n_sessions','mean_of_session_means', ...
                                           'sd_of_session_means','cv_pct','slope_per_session'});
writetable(SS, fullfile(resFolder, sprintf('TORQUE_SESSIONS_%s.csv', participant)));
writetable(PH, fullfile(resFolder, sprintf('TORQUE_PHASE_%s.csv', participant)));

% ===== figure 1: characterization curves and the operating points =====
fig = figure('Color','w','Visible','off','Position',[100 100 1000 650]); hold on; grid on; box on;
for i = 1:11, plot(LX{i}, LY{i}, '-', 'Color', [0.82 0.82 0.82]); end
ag = (-5:0.1:15)'; cl_ = zeros(size(ag)); cu_ = cl_;
for q = 1:numel(ag), [cl_(q), cu_(q)] = labTorque(CV, ag(q)); end
h1 = plot(ag, cl_, 'k-', 'LineWidth', 1.8);
h2 = plot(ag, cu_, 'k--', 'LineWidth', 1.2);
h3 = plot(DF_REF, T12, 'kp', 'MarkerFaceColor', 'y', 'MarkerSize', 12);
ib = T.condition == BASELINE_LABEL & isfinite(T.torque_loading_Nm);
ii = T.condition == INTERV_LABEL   & isfinite(T.torque_loading_Nm);
hList = [h1 h2 h3]; lList = {'this setting, loading','this setting, unloading','setting at 12 deg'};
if any(ib)
    hList(end+1) = scatter(T.maxDF_deg(ib), T.torque_loading_Nm(ib), 45, COL_BASE, 'filled');
    lList{end+1} = 'trial mean, AFO';
end
if any(ii)
    hList(end+1) = scatter(T.maxDF_deg(ii), T.torque_loading_Nm(ii), 45, COL_INT, 'filled');
    lList{end+1} = 'trial mean, AFO+AR';
end
xlim([-5 15]); ylim([min(cl_)-2, max(T12, max(cl_))+3]);
xlabel('Ankle angle (deg, dorsiflexion +)'); ylabel('Orthosis torque (Nm)');
title(sprintf(['%s - slider %.1f mm (%.2f Nm at %d deg = %.3f Nm/kg); grey = the 11 ' ...
               'characterized settings'], participant, SLIDER_MM, T12, DF_REF, coef));
legend(hList, lList, 'Location','northwest');
exportgraphics(fig, fullfile(figFolder, 'characterization.png'), 'Resolution', 150);
close(fig);

% ===== figure 2: per session =====
fig = figure('Color','w','Visible','off','Position',[100 100 1300 470]);
tl2 = tiledlayout(1, 2, 'TileSpacing','compact');
title(tl2, sprintf('%s - orthosis leg, every trial and session mean \\pm SD', participant), ...
      'FontWeight','bold');
phaseLine = NaN; if ~isempty(baseSess), phaseLine = max(baseSess) + 0.5; end
for v = 1:size(VARS,1)
    col = VARS{v,1};
    nexttile; hold on; grid on; box on;
    T.walk = zeros(height(T),1);
    for s = unique(T.session)'
        tr = unique(T.trial(T.session == s));
        for q = 1:numel(tr), T.walk(T.trial == tr(q)) = q; end
    end
    mb = T.condition == BASELINE_LABEL & isfinite(T.(col));
    mi = T.condition == INTERV_LABEL   & isfinite(T.(col));
    hList = gobjects(0); lList = {};
    if any(mb)
        hList(end+1) = scatter(T.session(mb) + (T.walk(mb)-2)*0.15, T.(col)(mb), 36, ...
                               COL_BASE, 'filled'); %#ok<AGROW>
        lList{end+1} = 'AFO (baseline)'; %#ok<AGROW>
    end
    if any(mi)
        hList(end+1) = scatter(T.session(mi) + (T.walk(mi)-2)*0.15, T.(col)(mi), 36, ...
                               COL_INT, 'filled'); %#ok<AGROW>
        lList{end+1} = 'AFO+AR'; %#ok<AGROW>
    end
    r = SS(SS.variable == string(col), :);
    hList(end+1) = errorbar(r.session, r.mean, r.sd, 'ks', 'MarkerFaceColor', 'w', ...
                            'LineWidth', 1.2, 'CapSize', 5); %#ok<AGROW>
    lList{end+1} = 'session mean \pm SD'; %#ok<AGROW>
    if isfinite(phaseLine)
        xline(phaseLine, '--', 'AR starts', 'LabelVerticalAlignment','bottom', 'Color', [0.4 0.4 0.4]);
    end
    xlim([min(T.session)-0.6, max(T.session)+0.6]); xticks(unique(T.session)');
    xlabel('Session'); ylabel(VARS{v,2});
    legend(hList, lList, 'Location','southoutside', 'Orientation','horizontal');
end
exportgraphics(fig, fullfile(figFolder, 'sessions.png'), 'Resolution', 150);
close(fig);

% ===== console summary =====
fprintf('\nSaved TORQUE_, TORQUE_SESSIONS_ and TORQUE_PHASE_%s.csv to %s\n', participant, resFolder);
fprintf('Stride cross-check against s2e ankle ROM: identical on all %d trials with a goniometer.\n', nCross);
fprintf('Strides whose max dorsiflexion lies outside the characterized angle range: %d.\n', nOut);
fprintf('\n=== PHASES (on session means) ===\n');
for q = 1:height(PH)
    fprintf('%-20s %-7s n=%d  mean %7.3f  sd %7.3f  cv %5.1f%%  slope %+.4f\n', PH.variable(q), ...
            PH.phase(q), PH.n_sessions(q), PH.mean_of_session_means(q), PH.sd_of_session_means(q), ...
            PH.cv_pct(q), PH.slope_per_session(q));
end
fprintf(['\nReminder: ~2.3 Nm per degree here, so the daily encoder zeroing moves the\n' ...
         'torque between sessions. Torque is descriptive (not a protocol outcome).\n']);

% ===== helpers =====
function y = closestY(x, yv, a)
% Lab rule: the sample whose angle is closest to a; exact zeros skipped (the lab
% code used 0 as padding and turned it into NaN); first one if tied.
    d = abs(x - a); d(d == 0) = NaN;
    [~, j] = min(d);
    y = yv(j);
end

function [tl, tu] = labTorque(CV, a)
% torqueCalculationLoss.m at one angle: loading and unloading torque on the
% curve interpolated between CV.f and CV.s with fraction CV.ratio.
    y1 = closestY(CV.LX{CV.f}, CV.LY{CV.f}, a);
    y2 = closestY(CV.LX{CV.s}, CV.LY{CV.s}, a);
    tl = y1 - CV.ratio*(y1 - y2);
    u1 = closestY(CV.UX{12-CV.f}, CV.UY{12-CV.f}, a);
    u2 = closestY(CV.UX{12-CV.s}, CV.UY{12-CV.s}, a);
    tu = u1 - CV.ratio*(u1 - u2);
end

function y = toUniform(tSrc, xSrc, tu)
% identical to s2e v6
    g = isfinite(tSrc) & isfinite(xSrc);
    if nnz(g) < 2, y = nan(numel(tu),1); return; end
    [tq, iq] = unique(tSrc(g));
    xg = xSrc(g);
    y  = interp1(tq, xg(iq), tu, 'linear', NaN);
end

function [stride, evT, pk] = stridesFrom(x, tu, inb, fsU, sep, lo, hi, minEv)
% identical to s2e v6 (mid-swing peaks, sub-sample refinement)
    stride = []; evT = []; pk = NaN;
    xb = x(inb); tb = tu(inb);
    g  = isfinite(xb);
    if nnz(g) < 100, return; end
    xb = xb(g); tb = tb(g);
    [pkv, loc] = findpeaks(xb, 'MinPeakHeight', 0.5*prctile(xb,99), ...
                               'MinPeakDistance', max(1,round(sep*fsU)));
    if numel(loc) < minEv, return; end
    evT = tb(loc);
    for j = 1:numel(loc)
        q = loc(j);
        if q > 1 && q < numel(xb) && (tb(q+1) - tb(q-1)) < 2.5/fsU
            y0 = xb(q-1); y1 = xb(q); y2 = xb(q+1);
            den = y0 - 2*y1 + y2;
            if den < 0
                dlt = 0.5*(y0 - y2)/den;
                if abs(dlt) <= 0.5, evT(j) = tb(q) + dlt/fsU; end
            end
        end
    end
    d = diff(evT);
    stride = d(d > lo & d < hi);
    if numel(stride) < minEv, stride = []; end
    pk = mean(pkv,'omitnan');
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
