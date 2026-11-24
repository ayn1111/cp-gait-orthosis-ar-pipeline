% s2c_Bundle.m   (v2 - also keeps the shank gyro and GaitUp at their NATIVE rate)
% =========================================================================
% STAGE 2, STEP 3 of 3.   Produces the files Stage 3 reads.
%
% WHAT THIS PROCESSES
%   RAW\inGAIT\InGait_<P>_*.csv                 reference timeline
%   PROCESSED\EMG\EMG_<P>_trial<k>_norm.mat     normalized envelopes (PASS 2)
%   RAW\IMU\gyro_topic_<P>_*.csv                shank IMUs
%   PROCESSED\GAITUP\GAITUP_<P>_trial<k>.mat    foot IMUs
%   PROCESSED\GAITUP\GAITUP_SHIFTS_<P>.csv      alignment from s2b
%
% WHAT IT ACHIEVES
%   PROCESSED\SYNC\<P>_trial<k>_sync.mat, one per trial, containing inGAIT_All:
%       .inGAIT    time_sec, angle_l/r, force_l/r, force_hl/hr
%       .EMG       time_sec + 8 muscle columns
%       .IMU       time_sec + shank gyro axes + L_mag / R_mag
%       .GAITUP_l  time_sec, AccX..GyrZ     (left foot, ROS clock)
%       .GAITUP_r  time_sec, AccX..GyrZ     (right foot, ROS clock)
%       .meta      provenance and per-stream validity
%   All five tables share ONE time base: inGAIT time_sec, zero at the first
%   inGAIT sample. Field names match what f_PushOffMetrics.m and
%   e_VR_section.m already expect, so those run unchanged.
%
%   v2 ADDS, on the same clock (same zero) but at each sensor's OWN samples:
%       .IMU_native        time_sec, L_mag, R_mag   (shank gyro, ~148 Hz)
%       .GAITUP_l_native   .acc (time_sec, AccX..AccZ), .gyr (time_sec, GyrX..GyrZ)
%       .GAITUP_r_native   same, right foot
%   and two meta fields: bundle_version (= 2) and IMU_native_fs.
%   Every v1 field is built by the SAME code as before and is unchanged, so
%   s2d's primary outcome does not move. s2d is re-run once as a check.
%
% ============ WHY v2 KEEPS THE NATIVE STREAMS ============
% v1 put every stream onto the inGAIT sample times. inGAIT is the reference
% clock, but its samples arrive irregularly: in session 6 they come in bursts
% (35-41 Hz on average) with 340-504 gaps longer than 0.1 s per trial, the
% longest 12 s. The shank IMU itself recorded at 148 Hz with NO gap longer
% than 0.07 s in any trial. Resampling it onto inGAIT's times threw that away:
% s2e found only 116-134 strides per session-6 trial against ~230 everywhere
% else. Strides, cadence and (later) foot trajectories must be computed from
% the native samples. The clock is unchanged - only the sampling is kept.
% =========================================================
%
% WHY THERE IS NO SEPARATE CUT STEP
%   d_Cut_data_all.m existed to trim four streams onto a common window after
%   the fact. Here inGAIT IS the window: everything is resampled onto its grid
%   and anything outside a stream's real coverage is NaN. Cutting is implicit.
%
% ================= TWO BUGS INHERITED AND FIXED =================
% 1. NO EXTRAPOLATION. b_Resample_data.m used interp1(...,'linear','extrap')
%    on every stream. On trial 9 the EMG covers 21% of the trial, so extrap
%    would have INVENTED the other 79% by continuing the last slope - and it
%    would have looked like ordinary data. Outside real coverage we write NaN.
%    Every downstream mean must therefore use 'omitnan'; f_PushOffMetrics
%    already does.
%
% 2. GAITUP VALIDITY IS CHECKED, NOT ASSUMED. s2b found one trial (17 for
%    CP03) where the two feet disagreed on the time shift by 336 s. Bundling
%    that would silently place foot data hundreds of seconds from where it
%    belongs. GaitUp is still written for such trials, because nothing is ever
%    excluded, but meta.gaitup_valid is false and Stage 3 must honour it.
%    The decision is recomputed here from corr_coarse and lr_shift_diff_s
%    rather than read from s2b's text flag, so a stale label cannot mislead it.
% ================================================================
%
% RUNTIME: ~5-10 minutes.
% =========================================================================

clear; clc;

% ===== USER SETTINGS =====
participant = 'CP03';
Root        = 'C:\INVESTIGACION CSIC\PAC03';
TrialMapCsv = fullfile(Root,'PROCESSED',sprintf('TRIALMAP_%s.csv',participant));
InGaitFolder= fullfile(Root,'RAW','inGAIT');
ImuFolder   = fullfile(Root,'RAW','IMU');
EmgMatFolder= fullfile(Root,'PROCESSED','EMG');
GaitupFolder= fullfile(Root,'PROCESSED','GAITUP');
ShiftsCsv   = fullfile(GaitupFolder,sprintf('GAITUP_SHIFTS_%s.csv',participant));
SaveFolder  = fullfile(Root,'PROCESSED','SYNC');

% Trigno sensor number -> muscle. Sensor k carries BOTH emg k and gyro k.
SensorsNames = {'GL_l','TA_l','GM_r','SOL_l','SOL_r','GL_r','GM_l','TA_r'};
GYRO.L = [2 4 7];       % left shank sensors
GYRO.R = [3 5 8];       % right shank sensors

% GaitUp is trusted only if BOTH hold. Same constants as s2b.
THR.corr_coarse = 0.50;
THR.lr_diff     = 3.0;
DEAD_STD        = 1.0;
% =========================

if ~exist(SaveFolder,'dir'), mkdir(SaveFolder); end
M = loadMap(TrialMapCsv);

SH = table();
if isfile(ShiftsCsv)
    SH = readtable(ShiftsCsv,'TextType','string');
else
    warning('No %s - GaitUp will not be bundled for any trial.', ShiftsCsv);
end

fprintf('%-3s %-3s %-8s %7s %9s %8s %8s %9s %9s  %s\n', ...
        'tr','S','fs_inG','dur_s','EMGcov%','IMUcov%','GUcov_L','GUcov_R','GUvalid','notes');
fprintf('%s\n', repmat('-',1,104));

nOK = 0; noEMG = {}; noGU = {};
for i = 1:height(M)
    k = M.trial(i); s = M.session(i);
    igF  = fullfile(InGaitFolder, char(M.inGAIT_file(i)));
    imuF = fullfile(ImuFolder,    char(M.IMU_file(i)));
    emgF = fullfile(EmgMatFolder, sprintf('EMG_%s_trial%d_norm.mat', participant, k));
    gupF = fullfile(GaitupFolder, sprintf('GAITUP_%s_trial%d.mat',   participant, k));

    if ~isfile(igF)
        fprintf('%-3d %-3d   inGAIT missing - trial cannot be bundled\n', k, s); continue;
    end

    % ================= reference timeline =================
    T   = readtable(igF,'Delimiter',',','TextType','string');
    ros = double(T.ros_timestamp);
    i0  = ros(1);
    inGAIT = table();
    inGAIT.time_sec = (ros - i0)*1e-9;
    skip = {'ros_timestamp','bag_time_s','header_timestamp'};
    for c = 1:numel(T.Properties.VariableNames)
        nm = T.Properties.VariableNames{c};
        if ismember(nm, skip), continue; end
        inGAIT.(nm) = double(T.(nm));
    end
    tG    = inGAIT.time_sec;
    fs_in = (numel(tG)-1)/tG(end);
    notes = {};

    % ================= EMG =================
    EMGt = table(); EMGt.time_sec = tG;
    for c = 1:8, EMGt.(SensorsNames{c}) = nan(numel(tG),1); end
    emgCov = 0; emgSrc = "none"; emgNorm = false;
    if isfile(emgF)
        S = load(emgF,'EMG'); E = S.EMG;
        te = (double(E.Epoch_ns) - i0)*1e-9;       % EMG on the inGAIT timeline
        emgCov = 100*(min(tG(end),te(end)) - max(0,te(1)))/tG(end);
        emgNorm = isfield(E,'Normalized') && E.Normalized;
        emgSrc  = string(char(M.EMG_file(i)));
        for c = 1:8
            EMGt.(SensorsNames{c}) = resampleNaN(te, E.Norm(:,c), tG);
        end
        if ~emgNorm
            notes{end+1} = 'EMG NOT normalized - re-run s1b PASS 2'; %#ok<AGROW>
        end
    else
        noEMG{end+1} = k; %#ok<AGROW>
        notes{end+1} = 'no EMG'; %#ok<AGROW>
    end

    % ================= shank IMU =================
    IMUt = table(); IMUt.time_sec = tG; imuCov = 0; liveAll = [];
    IMUn = table();                                  % v2: native-rate copy
    if isfile(imuF)
        G   = readtable(imuF);
        gts = double(G.ros_timestamp);
        ti  = (gts - i0)*1e-9;
        imuCov = 100*(min(tG(end),ti(end)) - max(0,ti(1)))/tG(end);
        for ss = 1:8
            ax = zeros(numel(gts),3);
            for a = 1:3
                ax(:,a) = G.(sprintf('gyro%d_%c', ss, char('w'+a)));   % x y z
            end
            if max(std(ax)) <= DEAD_STD, continue; end
            liveAll(end+1) = ss; %#ok<AGROW>
            for a = 1:3
                IMUt.(sprintf('%s_Gyr%c', SensorsNames{ss}, char('W'+a))) = ...
                    resampleNaN(ti, ax(:,a), tG);
            end
        end
        % per-side magnitude: the signal used for gait events and for the
        % GaitUp alignment, stored so Stage 3 does not recompute it.
        for sd = {'L','R'}
            sens = intersect(GYRO.(sd{1}), liveAll);
            v = zeros(numel(gts),1);
            for ss = sens
                m = sqrt(G.(sprintf('gyro%d_x',ss)).^2 + G.(sprintf('gyro%d_y',ss)).^2 + ...
                         G.(sprintf('gyro%d_z',ss)).^2);
                v = v + m/prctile(m,95);
            end
            if ~isempty(sens), v = v/numel(sens); else, v(:) = NaN; end
            IMUt.(sprintf('%s_mag',sd{1})) = resampleNaN(ti, v, tG);
            % v2: the same magnitude at the IMU's own sample times
            if isempty(IMUn), IMUn = table(ti, 'VariableNames', {'time_sec'}); end
            IMUn.(sprintf('%s_mag',sd{1})) = v;
        end
    else
        notes{end+1} = 'no IMU'; %#ok<AGROW>
    end

    % ================= GaitUp =================
    GLt = []; GRt = []; guCov = [NaN NaN]; guValid = false; GaitParameters = [];
    GLn = []; GRn = [];                              % v2: native-rate copies
    if isfile(gupF) && ~isempty(SH)
        L = load(gupF,'GAITUP'); GU = L.GAITUP;
        rL = SH(SH.trial==k & SH.foot=="left",  :);
        rR = SH(SH.trial==k & SH.foot=="right", :);

        okL = ~isempty(rL) && rL.corr_coarse(1) >= THR.corr_coarse;
        okR = ~isempty(rR) && rR.corr_coarse(1) >= THR.corr_coarse;
        lrd = NaN;
        if ~isempty(rL), lrd = rL.lr_shift_diff_s(1); end
        guValid = okL && okR && (isnan(lrd) || lrd <= THR.lr_diff);
        if ~guValid
            notes{end+1} = 'GAITUP ALIGNMENT NOT TRUSTED'; %#ok<AGROW>
        end

        if ~isempty(rL) && isfield(GU,'Acc_l')
            [GLt, guCov(1), GLn] = buildGaitup(GU.Acc_l, GU.Gyr_l, rL.epoch0_ns(1), i0, tG);
        end
        if ~isempty(rR) && isfield(GU,'Acc_r')
            [GRt, guCov(2), GRn] = buildGaitup(GU.Acc_r, GU.Gyr_r, rR.epoch0_ns(1), i0, tG);
        end
        if isfield(GU,'GaitParameters'), GaitParameters = GU.GaitParameters; end
    else
        noGU{end+1} = k; %#ok<AGROW>
        notes{end+1} = 'no GaitUp'; %#ok<AGROW>
    end

    % ================= bundle =================
    inGAIT_All = struct();
    inGAIT_All.inGAIT = inGAIT;
    inGAIT_All.EMG    = EMGt;
    inGAIT_All.IMU    = IMUt;
    if ~isempty(GLt), inGAIT_All.GAITUP_l = GLt; end
    if ~isempty(GRt), inGAIT_All.GAITUP_r = GRt; end
    if ~isempty(GaitParameters), inGAIT_All.GaitParameters = GaitParameters; end
    % v2: native-rate streams, same clock
    if ~isempty(IMUn), inGAIT_All.IMU_native = IMUn; end
    if ~isempty(GLn),  inGAIT_All.GAITUP_l_native = GLn; end
    if ~isempty(GRn),  inGAIT_All.GAITUP_r_native = GRn; end

    inGAIT_All.meta = struct( ...
        'participant',   participant, ...
        'trial',         k, ...
        'session',       s, ...
        'condition',     char(M.condition(i)), ...
        'fs_inGAIT',     fs_in, ...
        'duration_s',    tG(end), ...
        'EMG_source',    emgSrc, ...
        'EMG_coverage',  emgCov, ...
        'EMG_normalized',emgNorm, ...
        'IMU_coverage',  imuCov, ...
        'IMU_live',      liveAll, ...
        'GAITUP_cov_L',  guCov(1), ...
        'GAITUP_cov_R',  guCov(2), ...
        'gaitup_valid',  guValid, ...
        'muscles',       {SensorsNames}, ...
        'bundle_version',2, ...
        'IMU_native_fs', nativeRate(IMUn), ...
        'built',         datestr(now));

    save(fullfile(SaveFolder, sprintf('%s_trial%d_sync.mat', participant, k)), 'inGAIT_All');
    nOK = nOK + 1;

    fprintf('%-3d %-3d %8.1f %7.1f %9.0f %8.0f %8.0f %9.0f %9s  %s\n', ...
            k, s, fs_in, tG(end), emgCov, imuCov, guCov(1), guCov(2), ...
            string(guValid), strjoin(notes,'; '));
end

fprintf('\n=== DONE ===\n');
fprintf('%d of %d trials bundled into %s\n', nOK, height(M), SaveFolder);
if nOK == 0
    error('Nothing was bundled. Check the folder settings at the top of this script.');
end
if ~isempty(noEMG), fprintf('No EMG: trial(s) %s\n', mat2str(cell2mat(noEMG))); end
if ~isempty(noGU),  fprintf('No GaitUp: trial(s) %s\n', mat2str(cell2mat(noGU))); end
fprintf(['\nEvery stream sits on the inGAIT time base. Outside a stream''s real\n' ...
         'coverage the value is NaN, never an extrapolation, so any average taken\n' ...
         'downstream must use ''omitnan''.\n']);
fprintf(['\nv2: IMU_native and GAITUP_*_native hold the same signals at their own\n' ...
         'sample times, on the same clock. s2e computes strides from IMU_native.\n']);
fprintf('\nNEXT: s2d_PushOffMetrics.m (check run - PUSHOFF must not change), then s2e.\n');

% ===== helpers =====
function y = resampleNaN(tSrc, xSrc, tTarget)
% interp1 onto tTarget with NaN outside the source range. Never extrapolates:
% inventing data outside real coverage is how trial 9 would have gained 79%
% of an EMG recording that does not exist.
    tSrc = double(tSrc(:)); xSrc = double(xSrc(:));
    good = isfinite(tSrc);
    tSrc = tSrc(good); xSrc = xSrc(good);
    [tu, iu] = unique(tSrc);
    if numel(tu) < 2, y = nan(numel(tTarget),1); return; end
    y = interp1(tu, xSrc(iu), tTarget, 'linear', NaN);
end

function [Tb, cov, Nat] = buildGaitup(A, Gy, epoch0_ns, i0_ns, tTarget)
% Put one GaitUp foot on the inGAIT timeline.
% v2: Nat holds the same samples at their native times (same clock).
%   epoch = epoch0_ns + t_device*1e9   (epoch0_ns comes from s2b)
%   inGAIT time = (epoch - i0_ns)*1e-9
    [ta, acc] = extractOne(A);
    [tg, gyr] = extractOne(Gy);
    off = (epoch0_ns - i0_ns)*1e-9;
    ta = ta + off;  tg = tg + off;
    Tb = table(); Tb.time_sec = tTarget;
    Tb.AccX = resampleNaN(ta, acc(:,1), tTarget);
    Tb.AccY = resampleNaN(ta, acc(:,2), tTarget);
    Tb.AccZ = resampleNaN(ta, acc(:,3), tTarget);
    Tb.GyrX = resampleNaN(tg, gyr(:,1), tTarget);
    Tb.GyrY = resampleNaN(tg, gyr(:,2), tTarget);
    Tb.GyrZ = resampleNaN(tg, gyr(:,3), tTarget);
    cov = 100*nnz(isfinite(Tb.GyrY))/numel(tTarget);
    Nat = struct();
    Nat.acc = table(ta, acc(:,1), acc(:,2), acc(:,3), ...
                    'VariableNames', {'time_sec','AccX','AccY','AccZ'});
    Nat.gyr = table(tg, gyr(:,1), gyr(:,2), gyr(:,3), ...
                    'VariableNames', {'time_sec','GyrX','GyrY','GyrZ'});
end

function fs = nativeRate(Tn)
% Average sample rate of a native table, from its total span.
    fs = NaN;
    if isempty(Tn) || height(Tn) < 2, return; end
    tt = Tn.time_sec(isfinite(Tn.time_sec));
    if numel(tt) < 2, return; end
    fs = (numel(tt)-1)/(max(tt)-min(tt));
end

function [t, XYZ] = extractOne(S)
    if isnumeric(S)
        XYZ = double(S(:,1:3)); t = double(S(:,4));
    elseif isstruct(S) && isfield(S,'t') && isfield(S,'x')
        t = double(S.t(:)); XYZ = double([S.x(:) S.y(:) S.z(:)]);
    elseif isstruct(S) && isfield(S,'t') && isfield(S,'data')
        t = double(S.t(:)); XYZ = double(S.data(:,1:3));
    else
        error('Unknown GaitUp layout.');
    end
end

function M = loadMap(csvPath)
% Local copy of loadTrialMap so this script needs nothing on the MATLAB path.
% gaitup_day holds 20260824, which readtable imports as a double unless told
% otherwise; char() on that yields a garbage character and every path breaks.
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
