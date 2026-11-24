% s2d_PushOffMetrics.m   (v4.1 - adds gain-invariant within-trial ratios)
% v4.1 changes TEXT ONLY: the method description written to METHODS_<P>.txt
% and the console checklist were left over from the automatic heel-lift
% detector that was abandoned. Every number is computed exactly as in v4.
% =========================================================================
% STAGE 2, step 5.   PRIMARY OUTCOME.
%
% This is your f_PushOffMetrics.m. The contact detection, the 51-100% push-off
% window, the merged-contact rejection and the median statistics are UNCHANGED.
%
% ============ WHAT THE 51-100% WINDOW IS MEASURED OVER ============
% 51-100% of FOREFOOT CONTACT, exactly as f_PushOffMetrics always did.
% This study does not measure heel strike - the heel FSRs read flat all
% study (1st-99th percentile range 0.4-0.7 counts on all 30 trials) because
% heel contact is not what is being captured. Forefoot contact IS the
% contact phase for this investigation. Do not substitute a stance-phase
% definition taken from elsewhere.
% ==================================================================
%
% ============ v4: WITHIN-TRIAL RATIOS (added, nothing replaced) ============
% Every v3 column is computed exactly as before and comes out identical.
% Four columns are ADDED:
%
%   pushForce_ratio   = mean over cycles of (push-off force - unloaded level)
%                       / mean over cycles of (whole-contact force - unloaded level)
%   pushEMG_<m>_ratio = mean over cycles of push-off EMG envelope
%                       / mean over cycles of whole-contact EMG envelope
%
% WHY. The insole and the EMG electrodes are refitted every session, and each
% fitting has its own scale (gain). Across CP03's ten sessions the absolute
% push-off values swing by 2.4x (right force), 65x (left force), 22x (SOL_r)
% and 49x (GM_r) - far beyond anything a child's gait can do. Dividing two
% numbers recorded with the SAME fitting in the SAME step cancels that scale.
% Measured spread across sessions with the ratio: 1.3x, 1.4x, 1.5x, 3.5x.
%
% WHY THE FORCE RATIO SUBTRACTS THE UNLOADED LEVEL. An FSR reads roughly
%   offset + gain x load.
% (gain*push)/(gain*contact) cancels the gain; (offset+gain*push)/
% (offset+gain*contact) does not. The unloaded level is 'base', the 10th
% percentile of the force in the trial window - the foot in swing - which
% this script already computes for contact detection. EMG needs no
% subtraction: band-pass filtering leaves no offset.
%
% WHAT THE RATIO MEANS. The SHARE of each step's force (or muscle activity)
% that occurs in push-off. It does not measure HOW MUCH force in absolute
% terms. Both the protocol measure (pushForce_mean) and this ratio go through
% the analysis; neither replaces the other. The unloaded level is written out
% as fsrUnloaded so the subtraction is auditable.
%
% Ratio of means across cycles (sum of push / sum of contact), not mean of
% per-cycle ratios, so a cycle with a small denominator cannot dominate.
% ===========================================================================
%
% ============ THE TRIAL START ============
% f_PushOffMetrics analysed the WHOLE recording, so everything before the
% walk - standing, instrumentation, the heel lifts themselves - contributed
% contacts. The protocol marks the start of each trial with THREE HEEL
% LIFTS, so the analysis window begins at the last of them.
%
% The lift times are READ FROM HEELLIFTS_<P>.csv, which you fill in by eye
% using the figures from s2c1_MarkHeelLifts.m. They are NOT detected here.
% Two automatic detectors were tried and both failed: one returned up to 120
% "lifts" per trial by picking up quantisation noise, the other was stable
% but found two excursions where the protocol says three. P001 did this the
% same way - c_syncFinal.m carried a hand-typed rHeel array, half of it NaN.
%
% FALLBACK where the CSV row is NaN: the start of the walking bout from the
% shank gyro on the goniometer side, which is present on all 30 trials.
% Expected on trials 5, 6, 10, 11, 12, 16, 17 and 18 - the eight with a dead
% or wrapping goniometer - plus any you could not identify.
%
% Which was used on each trial is written to METHODS_<P>.txt and to the
% startFromHeelLift column, so the record is produced by the code.
%
% One consequence worth stating: the detection threshold is a percentile of
% the force INSIDE the analysis window, so restricting the window slightly
% changes the threshold compared with v1. That is correct - the percentiles
% should describe the trial, not the trial plus the standing before it.
% =============================================================
% Five things differ, all of them plumbing:
%     subject      P001 -> CP03
%     postFolder   PAC01 -> PAC03
%     trials       1:9 -> 1:30
%     PLOT_TRIAL   8 -> 1
%     filename     '%s_trial_%d_sync.mat' -> '%s_trial%d_sync.mat'
%                  (s2c writes CP03_trial1_sync.mat, no underscore before the
%                   number - my inconsistency, fixed here rather than in s2c
%                   so the already-bundled files stay valid)
%
% WHAT THIS PROCESSES
%   PROCESSED\SYNC\<P>_trial<k>_sync.mat   (from s2c)
%
% WHAT IT ACHIEVES
%   PROCESSED\SYNC\PUSHOFF_<P>.csv, one row per trial per foot:
%       pushForce_mean, pushForce_sd   forefoot FSR over 51-100% of contact
%       pushEMG_SOL, _GM, _TA          plantar flexors and tibialis anterior
%       contact_s, cadence_spm, nCycles
%
% NOTHING IS EXCLUDED. Trial 15 produces real force with NaN EMG, because the
% force exists and the EMG file does not. Trial 27's right foot produces a
% cadence built from 42 contacts; it is recorded, and ISSUES_<P>.txt says why
% it should not be trusted.
%
% pushForce_mean is in RAW FSR COUNTS. It is not comparable between feet or
% between sessions until Stage 4 divides it by the baseline reference.
% =========================================================================

clear; clc; close all;

% ===== USER SETTINGS =====
subject    = 'CP03';
postFolder = 'C:\INVESTIGACION CSIC\PAC03\PROCESSED\SYNC';
trials     = 1:30;
outCsv     = fullfile(postFolder, sprintf('PUSHOFF_%s.csv', subject));

MIN_CONTACT = 0.15;   % s, reject shorter contacts
MIN_CYCLE   = 0.50;   % s, reject shorter cycles
PLOT_TRIAL  = 1;      % set 0 to disable the check figure

gonioSide   = 'r';    % side with the goniometer (instrumentation fact)
FS_U        = 100;    % Hz, uniform grid for bout detection
heelCsv     = fullfile(postFolder, sprintf('HEELLIFTS_%s.csv', subject));
methodsTxt  = fullfile(postFolder, sprintf('METHODS_%s.txt', subject));

% Heel-lift table. Run s2c1_MarkHeelLifts.m and fill it in first.
if ~isfile(heelCsv)
    error(['%s not found.\n\nRun s2c1_MarkHeelLifts.m, mark the lifts on the ' ...
           'figures it produces, then run this script.'], heelCsv);
end
HL = readtable(heelCsv);
% =========================

rows = [];
fidM = fopen(methodsTxt,'w');
fprintf(fidM,'TRIAL START METHOD - participant %s\nGenerated %s by s2d_PushOffMetrics.\n\n', subject, datestr(now));
fprintf(fidM,['The protocol marks the start of each trial with three heel movements\n' ...
              '(heel DOWN, i.e. plantarflexion troughs in the ankle goniometer).\n' ...
              'START: the latest time entered for the trial in lift1_s..lift3_s of\n' ...
              '%s, marked BY EYE on the s2c1_MarkHeelLifts figures. Nothing\n' ...
              'is detected automatically. The note column of that file records how\n' ...
              'each row was obtained (measured troughs, or an investigator estimate\n' ...
              'where the goniometer was dead). FALLBACK, only where no time is\n' ...
              'entered: start of the walking bout from the shank gyro on the\n' ...
              'goniometer side.\n' ...
              'END: end of that walking bout. The window [START, END] is the one\n' ...
              'analysis window for the trial; s2e uses the identical rule.\n\n'], heelCsv);
fprintf(fidM,'%-6s %-6s %-12s %-10s %s\n','trial','sess','start_s','source','lift times (s)');
fprintf(fidM,'%s\n',repmat('-',1,78));
nHL = 0; nFB = 0;

fprintf('%-4s %-9s %-11s %s\n','tr','start_s','source','lifts');
for k = trials
    f = fullfile(postFolder, sprintf('%s_trial%d_sync.mat', subject, k));
    if ~isfile(f), fprintf('Trial %d MISSING\n',k); continue; end
    S = load(f); A = S.inGAIT_All;

    t  = double(A.inGAIT.time_sec);
    sess = NaN; if isfield(A,'meta') && isfield(A.meta,'session'), sess = A.meta.session; end

    % ---- walking bout from the shank gyro, on a UNIFORM grid ----
    % A sample count only means a duration when the spacing is constant, and
    % the inGAIT ROS samples arrive in bursts (session 6: true rate 35 Hz,
    % median gap equivalent to 4585 Hz). Everything that counts samples runs
    % on tu, never on t.
    tu = (t(1):1/FS_U:t(end))';
    boutStart = t(1); boutEnd = t(end);
    magCol = sprintf('%s_mag', upper(gonioSide));
    if ismember(magCol, A.IMU.Properties.VariableNames)
        magU = localUniform(t, double(A.IMU.(magCol)), tu);
        if ~all(isnan(magU))
            env = movmean(magU, round(1.0*FS_U), 'omitnan');
            hot = env > 0.25*prctile(env(isfinite(env)),99);
            run = round(4*FS_U);
            okb = movsum(hot,[0 run-1]) >= run;
            if any(okb)
                boutStart = tu(find(okb,1,'first'));
                boutEnd   = tu(min(numel(tu), find(okb,1,'last')+run-1));
            end
        end
    end

    % ---- trial start: last marked heel lift, else the walking bout ----
    [trialStart, startSrc, lifts] = localTrialStart(k, HL, boutStart);
    if strcmp(startSrc,'HEEL-LIFT'), nHL = nHL+1; else, nFB = nFB+1; end

    fprintf('%-4d %-9.1f %-11s %s\n', k, trialStart, startSrc, ...
            strjoin(arrayfun(@(x) sprintf('%.1f',x), lifts(:).', 'uni',0), ', '));
    fprintf(fidM,'%-6d %-6d %-12.2f %-10s %s\n', k, sess, trialStart, startSrc, ...
            strjoin(arrayfun(@(x) sprintf('%.2f',x), lifts(:).', 'uni',0), ', '));

    inWin = t >= trialStart & t <= boutEnd;

    for sd = {'l','r'}
        s = sd{1};
        Fall = double(A.inGAIT.(['force_' s]));       % forefoot FSR
        F    = Fall; F(~inWin) = NaN;                 % outside the trial window

        % --- toe-on / toe-off ---
        base = prctile(F(inWin),10); pk = prctile(F(inWin),90);
        if pk - base < eps, continue; end
        thr = base + 0.20*(pk-base);
        on  = F > thr;  on(isnan(F)) = false;
        d   = diff([0; on(:); 0]);
        ion = find(d==1); ioff = find(d==-1)-1;
        keep = (t(ioff)-t(ion)) >= MIN_CONTACT;
        ion = ion(keep); ioff = ioff(keep);
        if numel(ion) < 5, fprintf('Trial %d %s: too few contacts\n',k,upper(s)); continue; end
        good = [true; diff(t(ion)) >= MIN_CYCLE];
        ion = ion(good); ioff = ioff(good);
        % reject merged contacts (two steps detected as one)
        dur = t(ioff) - t(ion);
        okd = dur <= 1.5*median(dur);
        ion = ion(okd); ioff = ioff(okd);

        % --- EMG on the inGAIT grid ---
        tE = double(A.EMG.time_sec);
        mus = {'SOL','GM','TA'};
        E = struct();
        for mi = 1:numel(mus)
            fld = [mus{mi} '_' s];
            if ismember(fld, A.EMG.Properties.VariableNames)
                E.(mus{mi}) = interp1(tE, double(A.EMG.(fld)), t, 'linear', NaN);
            else
                E.(mus{mi}) = nan(size(t));
            end
        end

        % --- average over 51-100% of each contact ---
        nC = numel(ion);
        vF = nan(nC,1); vS = nan(nC,1); vG = nan(nC,1); vT = nan(nC,1);
        % v4: whole-contact means for the within-trial ratios
        cF = nan(nC,1); cS = nan(nC,1); cG = nan(nC,1); cT = nan(nC,1);
        for c = 1:nC
            i1 = ion(c); i2 = ioff(c);
            iMid = i1 + round(0.51*(i2-i1));
            if iMid >= i2, continue; end
            w = iMid:i2;
            vF(c) = mean(F(w),'omitnan');
            vS(c) = mean(E.SOL(w),'omitnan');
            vG(c) = mean(E.GM(w),'omitnan');
            vT(c) = mean(E.TA(w),'omitnan');
            wc = i1:i2;                                   % whole contact
            cF(c) = mean(F(wc),'omitnan');
            cS(c) = mean(E.SOL(wc),'omitnan');
            cG(c) = mean(E.GM(wc),'omitnan');
            cT(c) = mean(E.TA(wc),'omitnan');
        end

        % --- v4: gain-invariant within-trial ratios (see header) ---
        okF = isfinite(vF) & isfinite(cF);
        rF  = mean(vF(okF) - base,'omitnan') / mean(cF(okF) - base,'omitnan');
        rS  = localRatio(vS, cS);
        rG  = localRatio(vG, cG);
        rT  = localRatio(vT, cT);

        rows(end+1,:) = [k, sess, double(s=='r'), trialStart, double(strcmp(startSrc,'HEEL-LIFT')), nC, ...
                         mean(vF,'omitnan'), std(vF,'omitnan'), ...
                         mean(vS,'omitnan'), mean(vG,'omitnan'), mean(vT,'omitnan'), ...
                         median(t(ioff)-t(ion),'omitnan'), ...
                         60/median(diff(t(ion)),'omitnan'), ...
                         base, rF, rS, rG, rT]; %#ok<AGROW>

        if k == PLOT_TRIAL && s == 'r'
            figure('Color','w','Name',sprintf('Trial %d RIGHT - push-off detection',k));
            m = t>=t(ion(3)) & t<=t(ion(3))+8;
            plot(t(m), F(m)); grid on; hold on; yline(thr,'k--');
            for c = 1:numel(ion)
                if t(ion(c))<t(find(m,1)) || t(ion(c))>t(find(m,1,'last')), continue; end
                i1=ion(c); i2=ioff(c); iMid=i1+round(0.51*(i2-i1));
                xline(t(i1),'g-'); xline(t(i2),'r-');
                patch([t(iMid) t(i2) t(i2) t(iMid)], ...
                      [min(F(m)) min(F(m)) max(F(m)) max(F(m))], ...
                      [1 .85 .4],'FaceAlpha',.35,'EdgeColor','none');
            end
            xlabel('ROS time [s]'); ylabel('forefoot FSR');
            title('green = toe-on, red = toe-off, shaded = push-off (51-100%)');
        end
    end
end

fclose(fidM);
T = array2table(rows, 'VariableNames', {'trial','session','isRight','trialStart_s', ...
     'startFromHeelLift','nCycles', ...
     'pushForce_mean','pushForce_sd','pushEMG_SOL','pushEMG_GM','pushEMG_TA', ...
     'contact_s','cadence_spm', ...
     'fsrUnloaded','pushForce_ratio','pushEMG_SOL_ratio','pushEMG_GM_ratio','pushEMG_TA_ratio'});
disp(T);
writetable(T, outCsv);
fprintf('\nSaved -> %s\n', outCsv);

fprintf('\nTrial start: %d from heel lifts, %d from the walking-bout fallback.\n', nHL, nFB);
fprintf('Method per trial written to %s\n', methodsTxt);
fprintf('\n=== WHAT TO CHECK ===\n');
fprintf('  *_ratio        NEW in v4. Every older column must be identical to v3.\n');
fprintf('                 pushForce_ratio > 1 on a sound foot (push-off carries\n');
fprintf('                 more than the contact average). EMG ratios NaN wherever\n');
fprintf('                 the matching pushEMG_* column is NaN.\n');
fprintf('  startSource    fallback expected ONLY where HEELLIFTS_%s.csv has no time\n', subject);
fprintf('                 for the trial (CP03: trial 17 only).\n');
fprintf('  contact_s      0.5-0.7 s on the right, shorter on the left (heel-toe gait\n');
fprintf('                 loads the forefoot only in late stance).\n');
fprintf('  nCycles        200-270 on a sound foot. Far above means contacts are being\n');
fprintf('                 split; far below means they are being missed.\n');
fprintf('  pushEMG_*      NaN on trial 15 (no EMG file) and on any foot whose sensor\n');
fprintf('                 dropped out - trials 7 and 21 left SOL, trial 8 left GM.\n');
fprintf('  cadence_spm    STRIDES per minute from this FSR - a by-product, not an\n');
fprintf('                 outcome. Cadence in STEPS per minute is SPATIOTEMPORAL_%s.csv (s2e).\n', subject);

% ===== helpers =====
function r = localRatio(push, contact)
% Ratio of means across cycles, using only cycles where both exist. NaN when
% the channel is dead or absent, so a missing muscle never becomes a number.
    ok = isfinite(push) & isfinite(contact);
    if nnz(ok) < 10, r = NaN; return; end
    r = mean(push(ok)) / mean(contact(ok));
end

function y = localUniform(tSrc, xSrc, tu)
    g = isfinite(tSrc) & isfinite(xSrc);
    if nnz(g) < 2, y = nan(numel(tu),1); return; end
    [tq, iq] = unique(tSrc(g)); xg = xSrc(g);
    y = interp1(tq, xg(iq), tu, 'linear', NaN);
end

function [startSec, src, lifts] = localTrialStart(k, HL, boutStart)
% Trial start from the heel lifts you marked by eye. NO detection here.
% Uses the LAST lift time entered for this trial. Falls back to the start of
% the walking bout when the row holds no finite time.
    startSec = boutStart; src = 'WALK-BOUT'; lifts = [];
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
    lifts = sort(cand);
    startSec = lifts(end);
    src = 'HEEL-LIFT';
end
