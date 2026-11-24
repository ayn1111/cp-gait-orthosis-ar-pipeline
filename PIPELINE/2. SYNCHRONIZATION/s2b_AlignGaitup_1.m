% s2b_AlignGaitup.m   (v2 - corr threshold moved to coarse; self-contained)
% =========================================================================
% STAGE 2, STEP 2 of 3.
%
% WHAT THIS PROCESSES
%   PROCESSED\GAITUP\GAITUP_<P>_trial<k>.mat   (foot IMUs, GaitUp device clock)
%   RAW\IMU\gyro_topic_<P>_*.csv               (shank IMUs, ROS clock)
%   RAW\inGAIT\InGait_<P>_*.csv                (FSR, ROS clock - for validation)
%   PROCESSED\TRIALMAP_<P>.csv
%
% WHAT IT ACHIEVES
%   PROCESSED\GAITUP\GAITUP_SHIFTS_<P>.csv, one row per trial per foot:
%       epoch0_ns   the ROS epoch corresponding to GaitUp device time 0.
%                   After this, epoch = epoch0_ns + t_device*1e9, so GaitUp is
%                   on the same clock as inGAIT, EMG and the shank IMUs.
%       corr_coarse, corr_fine, shift_coarse_s, shift_fine_s
%       cad_gaitup, cad_fsr, cad_diff        (validation)
%       lr_shift_diff_s                      (validation)
%       flag
%
% METHOD
%   The GaitUp unit sits on the FOOT; the Trigno IMUs sit on the SHANK of the
%   same leg. Through swing the two segments rotate together, so their angular
%   velocity magnitudes are near-copies of each other with a small constant
%   phase offset. That makes the shank gyro a valid alignment reference, and
%   unlike the goniometer it is present and clean in all 30 trials.
%
%   1. Both signals reduced to gyro magnitude and resampled to FS_C.
%   2. COARSE: cross-correlate the 1 s envelopes over the full range. This
%      locks onto the overall shape of the walking bout (when walking starts,
%      when it stops), which is unique enough that it cannot land a whole
%      stride out.
%   3. FINE: cross-correlate the raw magnitude, searching only +/- FINE_WIN
%      around the coarse result. FINE_WIN is below half a gait cycle, so the
%      fine step physically cannot jump to the neighbouring stride.
%
% WHY NOT HEEL LIFTS (what c_syncFinal did for P001)
%   The three heel lifts were performed standing, so the forefoot was already
%   loaded and lifting the heel adds only 4-24 FSR counts on top of a baseline
%   of 36-65. The same sensor swings by 130-165 counts during walking. Checking
%   every trial of this participant, the clean set of three appears in exactly
%   one. Correlating 250 s of walking is far more robust than three small bumps,
%   and it needs no manual event picking.
%
% ============ RESIDUAL BIAS YOU SHOULD KNOW ABOUT ============
% Foot and shank do not peak at exactly the same instant, so this alignment
% carries a small systematic offset, of the order of tens of milliseconds.
% That is acceptable here because GaitUp is used only for the parameters a
% foot sensor alone can give - gait speed, stride length, minimum toe
% clearance. Push-off windows come from the FSR, which is natively on the ROS
% clock and needs no alignment at all. Do NOT start timing push-off events
% from GaitUp on the strength of this shift.
% =============================================================
%
% RUNTIME: ~5-10 minutes.
% =========================================================================

clear; clc;

% ===== USER SETTINGS =====
participant = 'CP03';
Root        = 'C:\INVESTIGACION CSIC\PAC03';
TrialMapCsv = fullfile(Root,'PROCESSED',sprintf('TRIALMAP_%s.csv',participant));
GaitupFolder= fullfile(Root,'PROCESSED','GAITUP');
ImuFolder   = fullfile(Root,'RAW','IMU');
InGaitFolder= fullfile(Root,'RAW','inGAIT');
OutCsv      = fullfile(GaitupFolder,sprintf('GAITUP_SHIFTS_%s.csv',participant));

% Shank IMU sensor numbers per side (Trigno sensor = EMG channel number)
GYRO.L = [2 4 7];      % TA_l, SOL_l, GM_l
GYRO.R = [3 5 8];      % GM_r, SOL_r, TA_r

FS_C      = 100;    % Hz, common grid for correlation
ENV_WIN   = 1.0;    % s, envelope smoothing for the coarse pass
FINE_WIN  = 0.30;   % s, fine search half-width. MUST stay below half a gait
                    % cycle (~0.5 s here) so fine cannot jump a stride.
DEAD_STD  = 1.0;    % deg/s, below this a gyro channel counts as not fitted

% Validation thresholds (fixed, same for every participant)
THR.corr_min   = 0.50;   % applies to corr_COARSE, not corr_fine. corr_fine
                         % compares FOOT gyro against SHANK gyro - different
                         % body segments, so it is legitimately lower and is
                         % information, not a test. On CP03 every trial scored
                         % 0.59+ on coarse except trial 17 at 0.48, so 0.50
                         % separates the one real failure from everything else.
THR.lr_diff    = 3.0;    % s, left vs right shift disagreement
THR.cad_diff   = 5.0;    % steps/min, GaitUp vs FSR
THR.cf_diff    = 1.0;    % s, coarse vs fine disagreement
% =========================

M    = loadMap(TrialMapCsv);   % local function at the end of this file
rows = cell(0,13);
nSkip = 0;

fprintf('%-3s %-3s %-5s %9s %9s %8s %8s %9s %9s  %s\n', ...
        'tr','S','foot','coarse_s','fine_s','corrC','corrF','cad_GU','cad_FSR','flag');
fprintf('%s\n', repmat('-',1,100));

for i = 1:height(M)
    k = M.trial(i); s = M.session(i);
    gupF = fullfile(GaitupFolder, sprintf('GAITUP_%s_trial%d.mat', participant, k));
    imuF = fullfile(ImuFolder,    char(M.IMU_file(i)));
    igF  = fullfile(InGaitFolder, char(M.inGAIT_file(i)));

    if ~isfile(gupF) || ~isfile(imuF)
        what = '';
        if ~isfile(gupF), what = [what 'GaitUp mat ']; end
        if ~isfile(imuF), what = [what 'IMU csv '];    end
        fprintf('%-3d %-3d   missing %s- skipped\n', k, s, what);
        nSkip = nSkip + 1; continue;
    end
    L = load(gupF,'GAITUP'); GAITUP = L.GAITUP;

    % ---- ROS shank gyro ----
    G   = readtable(imuF);
    gts = double(G.ros_timestamp);
    gt  = (gts - gts(1))*1e-9;

    % ---- FSR cadence, for validation ----
    cadFSR = [NaN NaN];
    if isfile(igF)
        T  = readtable(igF);
        its = double(T.ros_timestamp);
        tI  = (its - its(1))*1e-9;
        fn  = {'force_l','force_r'};
        for sIdx = 1:2
            F = double(T.(fn{sIdx}));
            p10 = prctile(F,10); p90 = prctile(F,90);
            d = diff([0; double(F > p10+0.20*(p90-p10)); 0]);
            ion = find(d==1); ioff = find(d==-1)-1;
            if numel(ion) > 5
                keep = (tI(ioff)-tI(ion))>=0.15; ion=ion(keep); ioff=ioff(keep);
                good = [true; diff(tI(ion))>=0.50]; ion=ion(good); ioff=ioff(good);
                dur  = tI(ioff)-tI(ion); okd = dur<=1.5*median(dur); ion=ion(okd);
                if numel(ion) > 50, cadFSR(sIdx) = 60/median(diff(tI(ion))); end
            end
        end
    end

    shiftFine = [NaN NaN];
    tmp = {};
    for sIdx = 1:2
        if sIdx==1, sd='L'; fld='Gyr_l'; lab='left';  else, sd='R'; fld='Gyr_r'; lab='right'; end

        if ~isfield(GAITUP,fld)
            fprintf('%-3d %-3d %-5s   no GaitUp data this foot\n', k,s,lab); continue;
        end

        % --- GaitUp foot gyro magnitude on its own clock ---
        [tG, XYZ] = extractOne(GAITUP.(fld));
        magG = sqrt(sum(XYZ.^2,2));
        tGr  = (tG(1):1/FS_C:tG(end))';
        gG   = interp1(tG, magG, tGr, 'linear', 'extrap');

        % --- ROS shank gyro magnitude, same side ---
        vv = zeros(numel(gt),1); nlive = 0;
        for ss = GYRO.(sd)
            m = sqrt(G.(sprintf('gyro%d_x',ss)).^2 + G.(sprintf('gyro%d_y',ss)).^2 + ...
                     G.(sprintf('gyro%d_z',ss)).^2);
            if std(m) > DEAD_STD, vv = vv + m/prctile(m,95); nlive = nlive+1; end
        end
        if nlive == 0
            fprintf('%-3d %-3d %-5s   no live shank gyro this side\n', k,s,lab); continue;
        end
        vv  = vv/nlive;
        tRr = (gt(1):1/FS_C:gt(end))';
        gR  = interp1(gt, vv, tRr, 'linear', 'extrap');

        z = @(x) (x-mean(x))/std(x);
        gGz = z(gG); gRz = z(gR);

        % --- COARSE: envelopes, full range ---
        w  = round(ENV_WIN*FS_C);
        eG = z(movmean(gGz,w));  eR = z(movmean(gRz,w));
        [cc, lagc] = xcorr(eR, eG);
        nrm = min(numel(eG),numel(eR));
        cc  = cc/nrm;
        [corrC, iC] = max(cc);
        shiftC = lagc(iC)/FS_C;             % ROS time = device time + shiftC

        % --- FINE: raw magnitude, restricted to +/- FINE_WIN of coarse ---
        [cf, lagf] = xcorr(gRz, gGz);
        cf  = cf/nrm;
        band = abs(lagf/FS_C - shiftC) <= FINE_WIN;
        cfb  = cf; cfb(~band) = -Inf;
        [corrF, iF] = max(cfb);
        shiftF = lagf(iF)/FS_C;

        shiftFine(sIdx) = shiftF;

        % epoch corresponding to GaitUp device time 0:
        %   epoch = gts(1) + (t_device + shiftF)*1e9
        epoch0 = gts(1) + shiftF*1e9;

        % --- GaitUp cadence (independent of the shift) ---
        [~,loc] = findpeaks(gG,'MinPeakHeight',0.5*prctile(gG,99), ...
                               'MinPeakDistance',round(0.70*FS_C));
        cadGU = NaN;
        if numel(loc) > 50
            iv = diff(tGr(loc)); iv = iv(iv>0.4 & iv<2.5);
            if numel(iv) > 20, cadGU = 60/median(iv); end
        end

        tmp(end+1,:) = {k,s,lab,shiftC,shiftF,corrC,corrF,epoch0,cadGU,cadFSR(sIdx)}; %#ok<AGROW>
    end

    % ---- validation and printing ----
    lrDiff = NaN;
    if all(isfinite(shiftFine)), lrDiff = abs(diff(shiftFine)); end
    for r = 1:size(tmp,1)
        corrC=tmp{r,6}; corrF=tmp{r,7}; shiftC=tmp{r,4}; shiftF=tmp{r,5};
        cadGU=tmp{r,9}; cadFSR_=tmp{r,10};
        cadDiff = abs(cadGU-cadFSR_);
        f = {};
        if corrC < THR.corr_min,                f{end+1}='LOW CORR';      end %#ok<AGROW>
        if abs(shiftC-shiftF) > THR.cf_diff,    f{end+1}='COARSE~=FINE';  end %#ok<AGROW>
        if isfinite(lrDiff) && lrDiff>THR.lr_diff, f{end+1}='L~=R SHIFT'; end %#ok<AGROW>
        if isfinite(cadDiff) && cadDiff>THR.cad_diff, f{end+1}='CADENCE'; end %#ok<AGROW>
        if isnan(cadGU) || isnan(cadFSR_),      f{end+1}='cad n/a';       end %#ok<AGROW>
        flag = 'ok'; if ~isempty(f), flag = strjoin(f,'+'); end
        fprintf('%-3d %-3d %-5s %9.3f %9.3f %8.3f %8.3f %9.2f %9.2f  %s\n', ...
                tmp{r,1},tmp{r,2},tmp{r,3},shiftC,shiftF,corrC,corrF,cadGU,cadFSR_,flag);
        rows(end+1,:) = {tmp{r,1},tmp{r,2},string(tmp{r,3}),shiftC,shiftF, ...
                         corrC,corrF,tmp{r,8},cadGU,cadFSR_,cadDiff,lrDiff,string(flag)}; %#ok<AGROW>
    end
end

if isempty(rows)
    error(['s2b aligned NOTHING - all %d trials were skipped.\n\n' ...
           'This means s2a produced no GAITUP_*.mat files, or GaitupFolder/ImuFolder\n' ...
           'point somewhere else. Re-run s2a and confirm it reports a non-zero count\n' ...
           'of trials written before running this script again.'], nSkip);
end

T = cell2table(rows,'VariableNames',{'trial','session','foot','shift_coarse_s', ...
    'shift_fine_s','corr_coarse','corr_fine','epoch0_ns','cad_gaitup','cad_fsr', ...
    'cad_diff','lr_shift_diff_s','flag'});
writetable(T, OutCsv);

fprintf('\nSaved -> %s\n', OutCsv);
fprintf('\n=== HOW TO READ THIS ===\n');
fprintf('A wrong alignment still produces output that looks reasonable, so judge it\n');
fprintf('on the three checks rather than on the shift value:\n');
fprintf('  1. COARSE~=FINE  the two passes disagree by more than %.1f s. The coarse\n', THR.cf_diff);
fprintf('                   pass found the bout in a different place than the fine one.\n');
fprintf('  2. L~=R SHIFT    the two feet give different answers by more than %.1f s,\n', THR.lr_diff);
fprintf('                   yet the units were started together. One side is wrong.\n');
fprintf('  3. CADENCE       GaitUp and the FSR disagree by more than %.1f steps/min.\n', THR.cad_diff);
fprintf('                   Independent hardware on independent clocks - this is the\n');
fprintf('                   strongest single check available.\n');
fprintf('\nCadence is computed from the GaitUp data alone, so it validates the DATA\n');
fprintf('regardless of the shift. The L~=R check is what validates the SHIFT.\n');
ok = nnz(T.flag == "ok");
fprintf('\n%d of %d feet clean.\n', ok, height(T));
fprintf('\nNEXT: s2c_Bundle.m\n');

% ===== helpers =====
function M = loadMap(csvPath)
% Local copy of the trial-map loader so this script needs NOTHING on the
% MATLAB path. gaitup_day holds 20260824, which readtable imports as a double
% unless told otherwise; char() on that yields a garbage character.
    if ~isfile(csvPath), error('Trial map not found:\n  %s', csvPath); end
    opts = detectImportOptions(csvPath,'TextType','string');
    txt  = intersect({'date','condition','inGAIT_file','EMG_file','IMU_file', ...
                      'gaitup_day','gaitup_LF','gaitup_RF','notes'}, opts.VariableNames);
    if ~isempty(txt), opts = setvartype(opts, txt, 'string'); end
    num  = intersect({'trial','session'}, opts.VariableNames);
    if ~isempty(num), opts = setvartype(opts, num, 'double'); end
    M = readtable(csvPath, opts);
    if height(M)==0, error('Trial map has no rows.'); end
end

function [t, XYZ] = extractOne(S)
    if isnumeric(S)
        XYZ = double(S(:,1:3)); t = double(S(:,4));
    elseif isstruct(S)
        if isfield(S,'t') && isfield(S,'x')
            t = double(S.t(:)); XYZ = double([S.x(:) S.y(:) S.z(:)]);
        elseif isfield(S,'t') && isfield(S,'data')
            t = double(S.t(:)); XYZ = double(S.data(:,1:3));
        else
            error('Unknown GAITUP struct layout.');
        end
    else
        error('Unsupported GAITUP format.');
    end
end
