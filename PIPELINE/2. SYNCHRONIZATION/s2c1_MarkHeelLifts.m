% s2c1_MarkHeelLifts.m
% =========================================================================
% STAGE 2, between s2c and s2d.   RUN ONCE PER PARTICIPANT.
%
% WHAT THIS PROCESSES
%   PROCESSED\SYNC\<P>_trial<k>_sync.mat
%
% WHAT IT ACHIEVES
%   PROCESSED\SYNC\HEELLIFTS\trial<k>.png     one figure per trial
%   PROCESSED\SYNC\HEELLIFTS_<P>.csv          template for you to fill in
%
%   You look at each figure, read off the times of the three heel lifts, and
%   type them into the CSV. s2d and s2e then read that CSV and start each
%   trial's analysis window at the LAST lift.
%
% ================== WHY THIS IS DONE BY EYE ==================
% The protocol marks the start of each trial with three heel lifts. I tried
% to detect them automatically twice and both attempts failed:
%
%   Attempt 1 - peak prominence relative to the pre-walk angle range. On
%   trials with a small range the threshold fell to its 0.8 deg floor, below
%   the quantisation noise, and it returned up to 120 "lifts" per trial. The
%   peaks it found sat at identical amplitudes (2.57, 2.53, 2.57, 2.52...),
%   which is a signal resting on a plateau, not a heel lift.
%
%   Attempt 2 - absolute prominence of 3-5 deg. This was stable, returning
%   the same count whether the threshold was 3, 4 or 5, so it is finding
%   something real. But it finds TWO excursions, and the protocol says three.
%   I cannot say which two of the three these are, or whether they are lifts.
%
% There is a precedent that settles it: c_syncFinal.m for P001 used a
% HAND-TYPED rHeel array, and half its entries were NaN. The heel lifts were
% identified by eye, trial by trial, and could not be found on every trial
% even then. Automatic detection was never how this worked.
%
% This script does the same thing, but the times live in a data file instead
% of being typed into a script, so the record is auditable.
% =============================================================
%
% The green markers on each figure are the prominence>=3 deg candidates. They
% are a VISUAL AID ONLY - nothing downstream reads them. Trust your eyes.
%
% WHAT A HEEL LIFT LOOKS LIKE
%   The participant is standing still, so the forefoot force is flat and
%   there is no stepping rhythm. Lifting the heel plantarflexes the ankle,
%   giving a distinct excursion of several degrees that returns to baseline.
%   Three of them, roughly a second apart, then walking begins.
%
% TRIALS YOU CANNOT MARK
%   8 of 30 have a dead or wrapping goniometer and show no usable angle
%   trace: trials 5, 6, 10, 11, 12, 16, 17 and 18. Leave those rows as NaN.
%   s2d and s2e fall back to the start of the walking bout and record that.
%
% RUNTIME: ~2 minutes.
% =========================================================================

clear; clc; close all;

% ===== USER SETTINGS =====
participant = 'CP03';
Root        = 'C:\INVESTIGACION CSIC\PAC03';
postFolder  = fullfile(Root,'PROCESSED','SYNC');
figFolder   = fullfile(postFolder,'HEELLIFTS');
outCsv      = fullfile(postFolder, sprintf('HEELLIFTS_%s.csv', participant));

gonioSide   = 'r';    % side with the goniometer (instrumentation fact)
trials      = 1:30;

FS_U        = 100;    % Hz, uniform grid for bout detection
CAND_PROM   = 3.0;    % deg, prominence of the candidate markers (visual aid)
PAD_AFTER   = 10;     % s of walking shown after the bout starts, for context
PHYS_ANGLE  = 60;     % deg, |angle| beyond this is a goniometer wrap
FLAT_RANGE  = 1.0;    % deg, robust p5-p95 below this means stuck
% =========================

if ~exist(figFolder,'dir'), mkdir(figFolder); end

% Never silently destroy marking you have already done.
if isfile(outCsv)
    error(['%s already exists.\n\nIf you have already marked the lifts, do not ' ...
           'run this script again - it would overwrite your work. To regenerate ' ...
           'the figures only, rename or move the CSV first.'], outCsv);
end

gyroSens = struct('l',[2 4 7],'r',[3 5 8]);
sens = gyroSens.(lower(gonioSide));

rows = [];
fprintf('%-4s %-12s %-11s %s\n','tr','boutStart_s','goniometer','figure');
fprintf('%s\n', repmat('-',1,62));

for k = trials
    f = fullfile(postFolder, sprintf('%s_trial%d_sync.mat', participant, k));
    if ~isfile(f), fprintf('%-4d  MISSING %s\n', k, f); continue; end
    S = load(f); A = S.inGAIT_All;

    t  = double(A.inGAIT.time_sec);
    tu = (t(1):1/FS_U:t(end))';

    % ---- walking bout from the gyro on the goniometer side ----
    % On a UNIFORM grid: a sample count only means a duration when the
    % spacing is constant, and the inGAIT ROS samples arrive in bursts.
    boutStart = NaN;
    magCol = sprintf('%s_mag', upper(gonioSide));
    if ismember(magCol, A.IMU.Properties.VariableNames)
        magU = localUniform(t, double(A.IMU.(magCol)), tu);
        if ~all(isnan(magU))
            env = movmean(magU, round(1.0*FS_U), 'omitnan');
            hot = env > 0.25*prctile(env(isfinite(env)),99);
            run = round(4*FS_U);
            okb = movsum(hot,[0 run-1]) >= run;
            if any(okb), boutStart = tu(find(okb,1,'first')); end
        end
    end
    if ~isfinite(boutStart), boutStart = t(1); end

    % ---- is the goniometer usable at all? ----
    ang = nan(size(t));
    angCol = ['angle_' lower(gonioSide)];
    if ismember(angCol, A.inGAIT.Properties.VariableNames)
        ang = double(A.inGAIT.(angCol));
    end
    robustRng = prctile(ang,95) - prctile(ang,5);
    wrapPct   = 100*mean(abs(ang) > PHYS_ANGLE);
    usable    = robustRng >= FLAT_RANGE && wrapPct <= 5;

    if usable
        state = 'usable';
    elseif robustRng < FLAT_RANGE
        state = 'STUCK';
    else
        state = 'WRAPPING';
    end

    % ---- figure ----
    m = t <= boutStart + PAD_AFTER;
    fig = figure('Color','w','Visible','off','Position',[100 100 1400 650]);
    tiledlayout(2,1);

    nexttile; hold on; grid on; box on;
    if usable
        plot(t(m), ang(m), 'LineWidth', 1.1);
        aw = ang(m); tw = t(m);
        keep = abs(aw) < PHYS_ANGLE;
        awk = aw(keep); twk = tw(keep);
        if numel(awk) > 20
            [~,loc] = findpeaks(awk, 'MinPeakProminence', CAND_PROM);
            plot(twk(loc), awk(loc), 'go', 'MarkerSize', 9, 'LineWidth', 1.4);
        end
        ylabel('ankle angle (deg)');
        title(sprintf(['Trial %d - read off the THREE heel lifts, then type their times ' ...
                       'into HEELLIFTS_%s.csv'], k, participant));
    else
        text(0.5,0.5,sprintf('goniometer %s - cannot mark this trial, leave the row as NaN',state), ...
             'Units','normalized','HorizontalAlignment','center','FontSize',13);
        axis off;
        title(sprintf('Trial %d - goniometer %s', k, state));
    end
    xline(boutStart,'r--','LineWidth',1.4);
    text(boutStart, double(max(ylim)), '  walking starts', 'Color','r', ...
         'VerticalAlignment','top');

    nexttile; hold on; grid on; box on;
    plot(t(m), double(A.inGAIT.(['force_' lower(gonioSide)])(m)), 'LineWidth', 1.1);
    xline(boutStart,'r--','LineWidth',1.4);
    xlabel('time within the trial (s)');
    ylabel('forefoot force (counts)');
    title('force is flat while standing - the lifts happen before any stepping rhythm');

    pngF = fullfile(figFolder, sprintf('trial%d.png', k));
    exportgraphics(fig, pngF, 'Resolution', 110);
    close(fig);

    rows(end+1,:) = [k, boutStart, double(usable), NaN, NaN, NaN]; %#ok<AGROW>
    fprintf('%-4d %-12.2f %-11s %s\n', k, boutStart, state, pngF);
end

T = array2table(rows, 'VariableNames', ...
      {'trial','bout_start_s','gonio_usable','lift1_s','lift2_s','lift3_s'});
writetable(T, outCsv);

fprintf('\n=== DONE ===\n');
fprintf('Figures : %s\n', figFolder);
fprintf('Template: %s\n', outCsv);
fprintf(['\nWHAT TO DO NOW\n' ...
         '  1. Open each PNG in %s\n' ...
         '  2. Read off the times of the three heel lifts.\n' ...
         '  3. Type them into lift1_s, lift2_s, lift3_s in the CSV.\n' ...
         '  4. Leave a row as NaN if you cannot identify them. Expect this on\n' ...
         '     trials 5, 6, 10, 11, 12, 16, 17 and 18 (goniometer dead or wrapping).\n' ...
         '  5. Then run s2d and s2e. They start each trial at the LAST lift you\n' ...
         '     typed, or at bout_start_s where the row is NaN, and they write\n' ...
         '     which was used into METHODS_%s.txt.\n'], figFolder, participant);
fprintf(['\nYou may enter fewer than three times if only two are identifiable.\n' ...
         'Only the LAST one you enter is used as the trial start.\n']);

% ===== helper =====
function y = localUniform(tSrc, xSrc, tu)
    g = isfinite(tSrc) & isfinite(xSrc);
    if nnz(g) < 2, y = nan(numel(tu),1); return; end
    [tq, iq] = unique(tSrc(g)); xg = xSrc(g);
    y = interp1(tq, xg(iq), tu, 'linear', NaN);
end
