% s2e_SpatioTemporal.m   (v6 - cadence in steps/min, native shank gyro, one window)
% =========================================================================
% STAGE 2, final step.   Secondary outcomes. Replaces g_SpatioTemporal.m.
%
% WHAT THIS PROCESSES
%   PROCESSED\SYNC\<P>_trial<k>_sync.mat   (bundle v2 from s2c - needs IMU_native)
%   PROCESSED\SYNC\HEELLIFTS_<P>.csv        (trial start, shared with s2d)
%   PROCESSED\TRIALMAP_<P>.csv
%
% WHAT IT ACHIEVES
%   PROCESSED\SYNC\SPATIOTEMPORAL_<P>.csv, one row per trial per side:
%     TRIAL-LEVEL (same value on both rows of a trial - see below)
%       strideTime_s             median stride time, both shank gyros pooled
%       cadence_steps_min        120 / strideTime_s          <- the outcome
%     PER SIDE
%       nStrides, strideTime_side_s, strideTime_iqr_s   this shank gyro alone
%       cadence_gaitup_steps_min, cadence_fsr_steps_min independent checks
%       cadence_spread_steps_min                        worst disagreement
%       ankleROM_deg, ankleROM_sd, nROM, gonio_wrap_pct
%       midSwingPeak_gyro, midSwingPeak_gaitup, windowEnd_s, note
%
% ================= WHAT v6 CHANGES, AND WHY =================
% 1. UNITS. v5 (and the lab's g_SpatioTemporal) reported 60/stride time.
%    That is STRIDES per minute - one gait cycle of one leg - and it was
%    labelled steps/min. Clinical cadence is STEPS per minute. Every stride
%    contains one left and one right step, so
%        cadence [steps/min] = 120 / stride time [s]
%    CP03 walks ~110-122 steps/min, not 55-61. Old P001 cadences from
%    g_SpatioTemporal are in strides/min and must be doubled before comparison.
%    Column names now carry the unit (_steps_min) so an old file cannot be
%    mistaken for a new one.
%
% 2. NATIVE GYRO. v5 detected strides on the shank gyro AFTER it had been
%    resampled onto the inGAIT sample times. In session 6 inGAIT has hundreds
%    of gaps up to 12 s, so half the strides were lost (116-134 per trial
%    against ~230 elsewhere). The IMU itself recorded at 148 Hz with no gaps.
%    v6 uses IMU_native (s2c v2): same clock, the sensor's own samples. The
%    148 Hz native samples (no gaps) are linearly interpolated onto the
%    uniform 100 Hz grid that findpeaks needs; the old route interpolated
%    across the inGAIT gaps instead.
%
% 3. ROBUST STRIDE TIME. Stride-to-stride, the detected mid-swing peak is not
%    always the same feature: on the orthosis side it can jump within the
%    stride (intervals such as 0.83, 1.37, 0.80 s that sum to two strides),
%    and turns or a missed peak add long intervals. The MEAN of the intervals
%    is pulled up by these (about +1% against the forefoot FSR on CP03); the
%    MEDIAN is not (pooled median -0.3%, mean absolute error 0.5%). v6
%    uses the median.
%    Peak times are refined to sub-sample precision (parabola through the
%    peak sample and its neighbours), so the median is not quantised to the
%    10 ms grid step - v5's cadence took only a handful of discrete values,
%    which produced exact ties between sessions.
%
% 4. CADENCE IS A PROPERTY OF THE TRIAL. Over one walk both legs complete
%    the same number of strides, so their stride times cannot differ; any
%    left/right difference is detection error. v6 pools the intervals of
%    BOTH shank gyros and takes one median per trial. This needs no choice of
%    leg, works for any participant, and was as accurate as the best single
%    leg on CP03. Each side's own median is kept (strideTime_side_s) as a
%    check: the two must agree within a few percent.
%
% 5. ONE WINDOW PER TRIAL. Start AND end now follow s2d exactly: start =
%    heel-down time from HEELLIFTS_<P>.csv (else walking-bout start), end =
%    end of the walking bout of the goniometer-side shank gyro. Every outcome
%    of a trial is computed over the same seconds.
% ============================================================
%
% =========== GONIOMETER VALIDITY: THREE FAILURE MODES ===========
%   STUCK     pinned at one value. Tested on the ROBUST range (5th to 95th
%             percentile), not min-to-max.
%   WRAPPING  running past its range (> 5% of samples beyond +/-60 deg).
%   GLITCHED  occasional single-stride excursions (> 90 deg), dropped
%             individually.
% Strides for ROM are delimited by consecutive mid-swing peaks of the
% goniometer-side shank gyro.
% ================================================================
%
% RUNTIME: ~2-4 minutes.
% =========================================================================

clear; clc; close all;

% ===== USER SETTINGS =====
participant = 'CP03';
Root        = 'C:\INVESTIGACION CSIC\PAC03';
postFolder  = fullfile(Root,'PROCESSED','SYNC');
TrialMapCsv = fullfile(Root,'PROCESSED',sprintf('TRIALMAP_%s.csv',participant));
outCsv      = fullfile(postFolder, sprintf('SPATIOTEMPORAL_%s.csv', participant));
heelCsv     = fullfile(postFolder, sprintf('HEELLIFTS_%s.csv', participant));

gonioSides  = {'r'};   % sides fitted with a goniometer (instrumentation fact)
refSide     = 'r';     % shank gyro that defines the walking bout - MUST equal
                       % gonioSide in s2d so both scripts share one window

FS_U        = 100;    % Hz, uniform grid for all peak and bout detection
MIN_STRIDE  = 0.50;   % s
MAX_STRIDE  = 2.50;   % s
MIN_EVENTS  = 10;
PEAK_SEP    = 0.70;   % s, minimum separation between mid-swing peaks
ROM_MAX     = 90;     % deg, single-stride excursion above this is a glitch
PHYS_ANGLE  = 60;     % deg, |angle| beyond this is a wrap
WRAP_MAX    = 5;      % %, above this ROM is not reportable for the trial
FLAT_RANGE  = 1.0;    % deg, robust (p5-p95) range below this means stuck
CAD_TOL     = 10;     % steps/min (= the 5 strides/min used in v5)
LR_TOL      = 3;      % %, left and right shank medians must agree within this
PLOT_TRIAL  = 0;
% =========================

if ~isfile(heelCsv)
    error(['%s not found.\n\nRun s2c1_MarkHeelLifts.m, mark the lifts, then ' ...
           'run s2d, then this script.'], heelCsv);
end
HL = readtable(heelCsv);
M  = loadMap(TrialMapCsv);
rows = {};

fprintf('%-3s %-3s %-4s %5s %9s %9s %9s %8s %8s %7s  %s\n', ...
        'tr','S','side','nStr','side_s','trial_s','cad','cad_gup','cad_fsr','ROM','note');
fprintf('%s\n', repmat('-',1,108));

for i = 1:height(M)
    k = M.trial(i); sess = M.session(i);
    f = fullfile(postFolder, sprintf('%s_trial%d_sync.mat', participant, k));
    if ~isfile(f), fprintf('%-3d  MISSING %s\n', k, f); continue; end
    S = load(f); A = S.inGAIT_All;
    if ~isfield(A,'IMU_native')
        error(['%s has no IMU_native table - it was bundled by s2c v1.\n' ...
               'Run s2c_Bundle.m (v2) first, then this script.'], f);
    end

    t  = double(A.inGAIT.time_sec);
    tu = (t(1):1/FS_U:t(end))';          % uniform grid; everything that counts samples runs on it
    guValid = isfield(A,'meta') && isfield(A.meta,'gaitup_valid') && A.meta.gaitup_valid;

    % ---------- ONE analysis window per trial: IDENTICAL rule and signal to s2d ----------
    boutStart = t(1); boutEnd = t(end);
    refCol = sprintf('%s_mag', upper(refSide));
    if ismember(refCol, A.IMU.Properties.VariableNames)
        magR = toUniform(t, double(A.IMU.(refCol)), tu);
        if ~all(isnan(magR))
            envR = movmean(magR, round(1.0*FS_U), 'omitnan');
            hotR = envR > 0.25*prctile(envR(isfinite(envR)),99);
            runR = round(4*FS_U);
            okR  = movsum(hotR,[0 runR-1]) >= runR;
            if any(okR)
                boutStart = tu(find(okR,1,'first'));
                boutEnd   = tu(min(numel(tu), find(okR,1,'last')+runR-1));
            end
        end
    end
    [b1, startSrc] = localTrialStart(k, HL, boutStart);
    b2 = boutEnd;
    if b2 <= b1
        fprintf('%-3d %-3d   window collapsed (start %.1f >= end %.1f)\n', k, sess, b1, b2);
        continue;
    end
    inb = tu >= b1 & tu <= b2;

    % ---------- strides from the NATIVE shank gyro, each side ----------
    tn = double(A.IMU_native.time_sec);
    St = struct();
    for sd = {'l','r'}
        s = sd{1};
        P = struct('stride',[], 'evT',[], 'pk',NaN);
        magCol = sprintf('%s_mag', upper(s));
        if ismember(magCol, A.IMU_native.Properties.VariableNames)
            magU = toUniform(tn, double(A.IMU_native.(magCol)), tu);
            if ~all(isnan(magU))
                [P.stride, P.evT, P.pk] = stridesFrom(magU, tu, inb, FS_U, ...
                                            PEAK_SEP, MIN_STRIDE, MAX_STRIDE, MIN_EVENTS);
            end
        end
        St.(s) = P;
    end

    % ---------- TRIAL-LEVEL stride time and cadence ----------
    pooled = [St.l.stride(:); St.r.stride(:)];
    strideTrial = NaN; cadTrial = NaN;
    if numel(pooled) >= MIN_EVENTS
        strideTrial = median(pooled);
        cadTrial    = 120/strideTrial;
    end
    medL = NaN; medR = NaN;
    if ~isempty(St.l.stride), medL = median(St.l.stride); end
    if ~isempty(St.r.stride), medR = median(St.r.stride); end
    lrPct = 100*abs(medL - medR)/mean([medL medR]);

    for sd = {'l','r'}
        s = sd{1}; SIDE = upper(s); note = {};
        P = St.(s);
        if strcmp(startSrc,'WALK-BOUT')
            note{end+1} = 'trial start from walking bout (heel lifts not marked)'; %#ok<AGROW>
        end

        nG = numel(P.stride); medS = NaN; iqrS = NaN;
        if nG > 0
            medS = median(P.stride);
            q = prctile(P.stride, [25 75]); iqrS = q(2) - q(1);
        else
            note{end+1} = 'this shank gyro gave too few strides'; %#ok<AGROW>
        end
        if isfinite(lrPct) && lrPct > LR_TOL
            note{end+1} = sprintf('L/R shank medians differ by %.1f%%', lrPct); %#ok<AGROW>
        end

        % ---------- GaitUp foot gyro (CHECK), native samples ----------
        cadGU = NaN; pkGU = NaN;
        guN = ['GAITUP_' s '_native'];
        if isfield(A, guN) && isfield(A.(guN), 'gyr')
            if ~guValid
                note{end+1} = 'GaitUp alignment not trusted, cadence still reported'; %#ok<AGROW>
            end
            Gn  = A.(guN).gyr;
            gyU = toUniform(double(Gn.time_sec), -double(Gn.GyrY), tu);   % swing peaks positive
            if ~all(isnan(gyU))
                [sGU, ~, pkGU] = stridesFrom(gyU, tu, inb, FS_U, ...
                                   PEAK_SEP, MIN_STRIDE, MAX_STRIDE, MIN_EVENTS);
                if ~isempty(sGU), cadGU = 120/median(sGU); end
            end
        end

        % ---------- forefoot FSR (CHECK) ----------
        % Stays on the inGAIT samples: every threshold here is in SECONDS.
        cadF = NaN;
        F  = double(A.inGAIT.(['force_' s]));
        m  = t >= b1 & t <= b2;
        Fb = F(m); tb = t(m);
        p10 = prctile(Fb,10); p90 = prctile(Fb,90);
        if p90 - p10 > eps
            d = diff([0; double(Fb > p10+0.20*(p90-p10)); 0]);
            ion = find(d==1); ioff = find(d==-1)-1;
            if numel(ion) > 3
                keep = (tb(ioff)-tb(ion)) >= 0.15; ion=ion(keep); ioff=ioff(keep);
            end
            if numel(ion) > 1
                good = [true; diff(tb(ion)) >= MIN_STRIDE]; ion=ion(good); ioff=ioff(good);
                dur  = tb(ioff)-tb(ion); okd = dur <= 1.5*median(dur); ion=ion(okd);
            end
            if numel(ion) > 50
                iv = diff(tb(ion)); iv = iv(iv > MIN_STRIDE & iv < MAX_STRIDE);
                if numel(iv) >= MIN_EVENTS, cadF = 120/median(iv); end
            else
                note{end+1} = sprintf('FSR gave only %d contacts', numel(ion)); %#ok<AGROW>
            end
        end

        % ---------- cross-check against the trial cadence ----------
        cads = [cadTrial cadGU cadF]; cads = cads(isfinite(cads));
        spread = NaN;
        if numel(cads) > 1, spread = max(cads)-min(cads); end
        if isfinite(spread) && spread > CAD_TOL
            note{end+1} = sprintf('cadence sources differ by %.1f steps/min', spread); %#ok<AGROW>
        end

        % ---------- ankle ROM ----------
        rom = NaN; romSd = NaN; nRom = 0; wrapPct = NaN;
        if ismember(s, lower(gonioSides))
            ang  = double(A.inGAIT.(['angle_' s]));
            angb = ang(t >= b1 & t <= b2);
            wrapPct   = 100*mean(abs(angb) > PHYS_ANGLE);
            robustRng = prctile(angb,95) - prctile(angb,5);
            evT = P.evT;
            if robustRng < FLAT_RANGE
                note{end+1} = 'goniometer stuck, no ROM'; %#ok<AGROW>
            elseif wrapPct > WRAP_MAX
                note{end+1} = sprintf('goniometer wrapping on %.0f%% of samples, ROM not reportable', wrapPct); %#ok<AGROW>
            elseif isempty(evT)
                note{end+1} = 'no strides, no ROM'; %#ok<AGROW>
            else
                r = nan(max(0,numel(evT)-1),1);
                for c = 1:numel(evT)-1
                    w = t >= evT(c) & t < evT(c+1);
                    if nnz(w) > 5
                        aw = ang(w);
                        if any(abs(aw) > PHYS_ANGLE), continue; end
                        rr = max(aw) - min(aw);
                        if rr <= ROM_MAX, r(c) = rr; end
                    end
                end
                nRom = nnz(isfinite(r));
                if nRom >= MIN_EVENTS
                    rom = mean(r,'omitnan'); romSd = std(r,'omitnan');
                else
                    note{end+1} = sprintf('only %d clean strides for ROM', nRom); %#ok<AGROW>
                end
            end
        end

        rows(end+1,:) = {k, sess, string(char(M.condition(i))), double(s=='r'), ...
            strideTrial, cadTrial, ...
            nG, medS, iqrS, ...
            b1, double(strcmp(startSrc,'HEEL-LIFT')), b2, ...
            cadGU, cadF, spread, rom, romSd, nRom, wrapPct, P.pk, pkGU, ...
            string(strjoin(note,'; '))}; %#ok<AGROW>

        fprintf('%-3d %-3d %-4s %5d %9.4f %9.4f %9.2f %8.2f %8.2f %7.2f  %s\n', ...
                k, sess, SIDE, nG, medS, strideTrial, cadTrial, cadGU, cadF, rom, ...
                strjoin(note,'; '));

        if k == PLOT_TRIAL && s == 'r'
            figure('Color','w','Name',sprintf('Trial %d RIGHT - stride detection',k));
            magU = toUniform(tn, double(A.IMU_native.R_mag), tu);
            w = tu>=b1 & tu<=b1+8;
            plot(tu(w), magU(w)); grid on; hold on;
            for c = 1:numel(P.evT)
                if P.evT(c)>=b1 && P.evT(c)<=b1+8, xline(P.evT(c),'g'); end
            end
            title('native shank gyro magnitude on the uniform grid; green = mid-swing');
            xlabel('ROS time [s]'); ylabel('normalised |gyro|');
        end
    end
end

if isempty(rows), error('No trial produced a row. Check the folder settings.'); end
T = cell2table(rows,'VariableNames',{'trial','session','condition','isRight', ...
     'strideTime_s','cadence_steps_min', ...
     'nStrides','strideTime_side_s','strideTime_iqr_s', ...
     'trialStart_s','startFromHeelLift','windowEnd_s', ...
     'cadence_gaitup_steps_min','cadence_fsr_steps_min','cadence_spread_steps_min', ...
     'ankleROM_deg','ankleROM_sd','nROM','gonio_wrap_pct', ...
     'midSwingPeak_gyro','midSwingPeak_gaitup','note'});
writetable(T, outCsv);
fprintf('\nSaved -> %s\n', outCsv);

% ===== checks =====
fprintf('\n=== CADENCE (steps/min), one value per trial ===\n');
R1 = T(T.isRight == 1, :);
fprintf('range %.1f - %.1f steps/min over %d trials\n', min(R1.cadence_steps_min), ...
        max(R1.cadence_steps_min), nnz(isfinite(R1.cadence_steps_min)));
v = T.cadence_spread_steps_min(isfinite(T.cadence_spread_steps_min));
fprintf('\n=== CROSS-CHECK ===\n');
fprintf('Cadence spread across instruments: median %.2f, max %.2f steps/min over %d sides.\n', ...
        median(v), max(v), numel(v));
bad = T(T.cadence_spread_steps_min > CAD_TOL, {'trial','isRight','cadence_steps_min', ...
        'cadence_gaitup_steps_min','cadence_fsr_steps_min'});
if isempty(bad)
    fprintf('Every side agrees within %.0f steps/min across all three instruments.\n', CAD_TOL);
else
    fprintf('\n%d side(s) where the instruments disagree:\n', height(bad));
    disp(bad);
    fprintf(['Read these by asking which TWO agree. The odd one out is the\n' ...
             'instrument that failed, and the other two carry the outcome.\n']);
end
L1 = T(T.isRight == 0, :);
[~, ia, ib] = intersect(L1.trial, R1.trial);
lr = 100*abs(L1.strideTime_side_s(ia) - R1.strideTime_side_s(ib)) ./ ...
     mean([L1.strideTime_side_s(ia) R1.strideTime_side_s(ib)], 2);
fprintf('Left vs right shank median stride: median difference %.2f%%, max %.2f%% (limit %d%%).\n', ...
        median(lr,'omitnan'), max(lr), LR_TOL);
r = T.ankleROM_deg(isfinite(T.ankleROM_deg));
fprintf('\nAnkle ROM available on %d of %d sides (goniometer side: %s).\n', ...
        numel(r), height(T), strjoin(upper(gonioSides),','));
fprintf('Check ankleROM_sd is SMALLER than ankleROM_deg on every row that has one.\n');

% ===== helpers =====
function [startSec, src] = localTrialStart(k, HL, boutStart)
% Trial start from the heel lifts marked by eye. IDENTICAL rule to s2d.
    startSec = boutStart; src = 'WALK-BOUT';
    r = find(HL.trial == k, 1);
    if isempty(r), return; end
    cand = [];
    for c = {'lift1_s','lift2_s','lift3_s'}
        if ismember(c{1}, HL.Properties.VariableNames)
            v = HL.(c{1})(r);
            if isfinite(v), cand(end+1) = v; end %#ok<AGROW>
        end
    end
    if isempty(cand), return; end
    startSec = max(cand); src = 'HEEL-LIFT';
end

function y = toUniform(tSrc, xSrc, tu)
% Put a signal onto the uniform grid. NaN outside the source range - never
% extrapolate.
    g = isfinite(tSrc) & isfinite(xSrc);
    if nnz(g) < 2, y = nan(numel(tu),1); return; end
    [tq, iq] = unique(tSrc(g));
    xg = xSrc(g);
    y  = interp1(tq, xg(iq), tu, 'linear', NaN);
end

function [stride, evT, pk] = stridesFrom(x, tu, inb, fsU, sep, lo, hi, minEv)
% Mid-swing peaks -> stride intervals. x and tu MUST be on a uniform grid:
% MinPeakDistance is a sample count and only means a duration when the
% spacing is constant. Each peak time is refined to sub-sample precision by
% the vertex of the parabola through the peak sample and its two neighbours
% (only when both neighbours are real, adjacent samples).
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

function M = loadMap(csvPath)
% Local copy so this script needs nothing on the MATLAB path.
    if ~isfile(csvPath), error('Trial map not found:\n  %s', csvPath); end
    opts = detectImportOptions(csvPath,'TextType','string');
    txt  = intersect({'date','condition','inGAIT_file','EMG_file','IMU_file', ...
                      'gaitup_day','gaitup_LF','gaitup_RF','notes'}, opts.VariableNames);
    if ~isempty(txt), opts = setvartype(opts, txt, 'string'); end
    num  = intersect({'trial','session'}, opts.VariableNames);
    if ~isempty(num), opts = setvartype(opts, num, 'double'); end
    M = readtable(csvPath, opts);
end
