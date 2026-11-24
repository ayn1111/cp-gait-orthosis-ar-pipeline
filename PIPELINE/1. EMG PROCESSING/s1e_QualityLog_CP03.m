% s1e_QualityLog_CP03.m   (v3)
% =========================================================================
% STAGE 1, STEP 5 of 5.   QUALITY RECORD. Excludes nothing.
%
% WHAT THIS PROCESSES
%   PROCESSED\EMG\EMG_<P>_trial<k>_norm.mat   (envelopes; PASS 1 or 2, either works)
%   RAW\IMU\gyro_topic_<P>_*.csv              (defines the walking bout AND the gait cycles)
%   RAW\inGAIT\InGait_<P>_*.csv               (force and angle quality)
%   PROCESSED\TRIALMAP_<P>.csv
%
% WHAT IT ACHIEVES - three files in PROCESSED\QC\, regenerated each run:
%   QC_CHANNELS_<P>.csv   one row per trial per EMG channel
%   QC_TRIALS_<P>.csv     one row per trial, all non-EMG metrics
%   ISSUES_<P>.txt        plain-language log, grouped by session
%
% ================== WHAT THIS SCRIPT DOES NOT DO ==================
% It does not drop, exclude, gate or modify any trial. Every trial of every
% patient is processed by the pipeline regardless of these numbers. All
% thresholds are fixed constants, identical for every participant, so no
% per-patient judgement is ever applied. The log exists so that at the final
% analysis you can run ONE pre-specified sensitivity check and report whether
% the conclusion changes.
% ==================================================================
%
% ===================== CHANGES FROM v2 (all bug fixes) ============
% 1. ONE BOUT DEFINITION. v2 located the walking bout from the FSR contact
%    train - the very signal being tested. When FSR detection degraded, the
%    bout collapsed and the pause metric silently under-reported (trial 12
%    read 0% against an actual ~49%). v3 takes the bout from the gyro, which
%    is clean in every trial and independent of everything being measured.
%    This is the same bout s1c uses, so the whole pipeline now agrees.
%
% 2. NO SILENT NaN. In v2, a metric that could not be computed produced no
%    log entry, so the worse a trial was, the quieter the log became. Trial 27
%    yields only 10 right-foot contacts in a 5-minute walk; v2 logged one line
%    about sensor range and nothing else. In v3 every uncomputable metric
%    writes an entry saying why.
%
% 3. MINIMUM CONTACT COUNT. Cadence and duty cycle are now refused below
%    THR.min_contacts events, instead of being computed from a handful of
%    detections and looking reasonable. Trial 27's "56.3 steps/min" in v2 came
%    from ten contacts.
% ==================================================================
%
% METRIC DEFINITIONS
%   burst_depth    Peak of the cycle-averaged EMG envelope over its 10th
%                  percentile. A muscle firing once per step gives a large
%                  value; a flat recording gives ~1. Scale-free, so comparable
%                  across sessions, channels and patients.
%   variance_ratio Step-to-step repeatability. 0 = identical, 1 = none. HIGH IS
%                  NOT A FAULT - variable activation is a real feature of
%                  neurological gait. Recorded, never flagged.
%   duty_cycle     FOREFOOT contact as % of stride, NOT stance. Heel-toe gait
%                  loads the forefoot only in late stance (~25%); toe contact
%                  loads it throughout stance (~52%). Both are correct.
%   cadence match  The two feet must report the same cadence. Independent of
%                  foot posture, so this is the real detection check.
%
% RUNTIME: ~5-10 minutes.
% =========================================================================

clear; clc;

% ===== USER SETTINGS =====
participant = 'CP03';
Root        = 'C:\INVESTIGACION CSIC\PAC03';
TrialMapCsv = fullfile(Root,'PROCESSED',sprintf('TRIALMAP_%s.csv',participant));
EmgMatFolder= fullfile(Root,'PROCESSED','EMG');
ImuFolder   = fullfile(Root,'RAW','IMU');
InGaitFolder= fullfile(Root,'RAW','inGAIT');
OutFolder   = fullfile(Root,'PROCESSED','QC');

% Sides fitted with a goniometer. An INSTRUMENTATION FACT from the session
% notes, not a judgement about the data. CP03 wears the orthosis on the right
% only, so angle_l is structurally absent. Bilateral: {'l','r'}.
gonioSides  = {'r'};

% ---- FIXED THRESHOLDS. Do not tune these per patient. ----
THR.burst_low     = 2.0;    % below this the channel shows no step-locked burst
THR.burst_marg    = 2.5;
THR.min_cycles    = 30;     % EMG gait cycles
THR.min_contacts  = 50;     % FSR contacts inside the bout, per foot
THR.emg_cov       = 90;     % % of trial covered by EMG
THR.duty_lo       = 15;     % forefoot contact as % of stride
THR.duty_hi       = 85;
THR.cad_mismatch  = 5;      % steps/min between feet
THR.fsr_span      = 20;     % counts, p10 to p90
THR.angle_span    = 1.0;    % degrees
THR.pause_frac    = 20;     % % of bout spent stopped
THR.fs_ingait     = 45;     % Hz
THR.min_bout      = 150;    % s; a 4-minute walk should exceed this
% =========================

CH     = [2 3 4 5 7 8];
CHNAME = {'TA_l','GM_r','SOL_l','SOL_r','GM_l','TA_r'};
CHSIDE = {'L','R','L','R','L','R'};
GYRO.L = [2 4 7];
GYRO.R = [3 5 8];
TRIM   = 2;      % s trimmed inward at each end of the bout

if ~exist(OutFolder,'dir'), mkdir(OutFolder); end
M = readtable(TrialMapCsv,'TextType','string');

chRows = {}; trRows = {}; issues = {};
add = @(s,k,tag,msg) {s,k,tag,msg};

for i = 1:height(M)
    k = M.trial(i); s = M.session(i);
    fprintf('Trial %2d (session %d)\n', k, s);

    matF = fullfile(EmgMatFolder, sprintf('EMG_%s_trial%d_norm.mat', participant, k));
    imuF = fullfile(ImuFolder,    char(M.IMU_file(i)));
    igF  = fullfile(InGaitFolder, char(M.inGAIT_file(i)));

    duty=[NaN NaN]; cad=[NaN NaN]; span=[NaN NaN]; arange=[NaN NaN];
    ncon=[0 0]; pausefrac=NaN; fsIG=NaN; cov=NaN; bout_s=NaN;

    % ================= 1. BOUT, from the gyro =================
    % Computed FIRST and used for everything below. The gyro is present and
    % clean in all 30 trials, and is independent of the FSR and EMG that this
    % script is testing.
    boutE = [NaN NaN]; ev = struct('L',[],'R',[]); haveGyro = false;
    if ~isfile(imuF)
        issues(end+1,:) = add(s,k,'IMU','gyro file missing - no walking bout, all metrics below are over the whole recording'); %#ok<AGROW>
    else
        G   = readtable(imuF);
        gts = double(G.ros_timestamp);
        gt  = (gts-gts(1))*1e-9;
        gfs = (numel(gt)-1)/gt(end);
        live = [];
        v = zeros(numel(gt),1);
        for ss = 1:8
            m = sqrt(G.(sprintf('gyro%d_x',ss)).^2 + G.(sprintf('gyro%d_y',ss)).^2 + ...
                     G.(sprintf('gyro%d_z',ss)).^2);
            if std(m) > 1, live(end+1) = ss; end %#ok<AGROW>
        end
        for ss = live
            m = sqrt(G.(sprintf('gyro%d_x',ss)).^2 + G.(sprintf('gyro%d_y',ss)).^2 + ...
                     G.(sprintf('gyro%d_z',ss)).^2);
            v = v + m/prctile(m,95);
        end
        if isempty(live)
            issues(end+1,:) = add(s,k,'IMU','every gyro flat - no walking bout available'); %#ok<AGROW>
        else
            v   = v/numel(live);
            w   = max(3, round(1.0*gfs));
            hot = movmean(v,w) > 0.25*prctile(movmean(v,w),99);
            run = max(3, round(4*gfs));
            ok  = movsum(hot,[0 run-1]) >= run;
            f = find(ok,1,'first'); l = find(ok,1,'last');
            if isempty(f)
                issues(end+1,:) = add(s,k,'IMU','no walking bout detected in the gyro'); %#ok<AGROW>
            else
                boutE  = [gts(f), gts(min(numel(gts), l+run-1))];
                bout_s = diff(boutE)*1e-9;
                haveGyro = true;
                if bout_s < THR.min_bout
                    issues(end+1,:) = add(s,k,'GAIT',sprintf('walking bout only %.0f s - expected over %d s',bout_s,THR.min_bout)); %#ok<AGROW>
                end
                for sd = {'L','R'}
                    vv = zeros(numel(gt),1); nlive = 0;
                    for ss = GYRO.(sd{1})
                        m = sqrt(G.(sprintf('gyro%d_x',ss)).^2 + G.(sprintf('gyro%d_y',ss)).^2 + ...
                                 G.(sprintf('gyro%d_z',ss)).^2);
                        if std(m) > 1, vv = vv + m/prctile(m,95); nlive = nlive+1; end
                    end
                    if nlive == 0, continue; end
                    [~,loc] = findpeaks(vv,'MinPeakHeight',0.5*prctile(vv,99), ...
                                           'MinPeakDistance',round(0.70*gfs));
                    ev.(sd{1}) = gts(loc);       % absolute epoch
                end
            end
        end
    end

    % ================= 2. inGAIT metrics, inside the bout =================
    if ~isfile(igF)
        issues(end+1,:) = add(s,k,'inGAIT','inGAIT file missing - no force or angle metrics'); %#ok<AGROW>
    else
        T  = readtable(igF);
        ts = double(T.ros_timestamp);
        tg = (ts - ts(1))*1e-9;
        fsIG = (numel(tg)-1)/tg(end);
        if haveGyro
            inb = ts >= boutE(1) & ts <= boutE(2);
        else
            inb = true(size(ts));
        end
        if nnz(inb) < 100
            issues(end+1,:) = add(s,k,'inGAIT','bout covers almost no inGAIT samples - check clock alignment'); %#ok<AGROW>
            inb = true(size(ts));
        end
        tb = tg(inb);
        arange(1) = prctile(T.angle_l(inb),99) - prctile(T.angle_l(inb),1);
        arange(2) = prctile(T.angle_r(inb),99) - prctile(T.angle_r(inb),1);

        sides = {'force_l','force_r'}; lab = {'left','right'};
        for sIdx = 1:2
            F = double(T.(sides{sIdx})(inb));
            p10 = prctile(F,10); p90 = prctile(F,90);
            span(sIdx) = p90 - p10;
            thr = p10 + 0.20*(p90-p10);
            d   = diff([0; double(F > thr); 0]);
            ion = find(d==1); ioff = find(d==-1)-1;
            if numel(ion) > 3
                keep = (tb(ioff)-tb(ion)) >= 0.15;  ion=ion(keep); ioff=ioff(keep);
            end
            if numel(ion) > 1
                good = [true; diff(tb(ion)) >= 0.50]; ion=ion(good); ioff=ioff(good);
                dur  = tb(ioff)-tb(ion);
                okd  = dur <= 1.5*median(dur);      ion=ion(okd);  ioff=ioff(okd);
            end
            ncon(sIdx) = numel(ion);

            if ncon(sIdx) < THR.min_contacts
                issues(end+1,:) = add(s,k,'FSR',sprintf(['%s foot: only %d contacts detected in a %.0f s bout - ' ...
                    'contact detection has failed, no cadence or push-off force for this foot'], ...
                    lab{sIdx}, ncon(sIdx), bout_s)); %#ok<AGROW>
            else
                cyc = diff(tb(ion));
                duty(sIdx) = 100*median(tb(ioff)-tb(ion))/median(cyc);
                cad(sIdx)  = 60/median(cyc);
                if sIdx == 2
                    pausefrac = 100*sum(cyc(cyc > 2.5))/sum(cyc);
                end
            end

            if span(sIdx) < THR.fsr_span
                issues(end+1,:) = add(s,k,'FSR',sprintf('%s forefoot range only %.0f counts - push-off force unreliable',lab{sIdx},span(sIdx))); %#ok<AGROW>
            end
            if ~isnan(duty(sIdx)) && (duty(sIdx) < THR.duty_lo || duty(sIdx) > THR.duty_hi)
                issues(end+1,:) = add(s,k,'FSR',sprintf('%s forefoot contact %.0f%% of stride - outside any plausible pattern',lab{sIdx},duty(sIdx))); %#ok<AGROW>
            end
            if ismember(lower(lab{sIdx}(1)), lower(gonioSides)) && arange(sIdx) < THR.angle_span
                issues(end+1,:) = add(s,k,'GONIO',sprintf('%s ankle angle flat - no range of motion available',lab{sIdx})); %#ok<AGROW>
            end
        end

        if all(~isnan(cad)) && abs(cad(1)-cad(2)) > THR.cad_mismatch
            issues(end+1,:) = add(s,k,'FSR',sprintf(['cadence disagrees between feet: left %.1f vs right %.1f steps/min - ' ...
                'contact detection has failed on one side'],cad(1),cad(2))); %#ok<AGROW>
        end
        if isnan(pausefrac)
            issues(end+1,:) = add(s,k,'GAIT','pause fraction could not be computed - right foot contact detection failed'); %#ok<AGROW>
        elseif pausefrac > THR.pause_frac
            issues(end+1,:) = add(s,k,'GAIT',sprintf('%.0f%% of the walking bout spent stopped',pausefrac)); %#ok<AGROW>
        end
        if fsIG < THR.fs_ingait
            issues(end+1,:) = add(s,k,'inGAIT',sprintf('logging rate only %.0f Hz',fsIG)); %#ok<AGROW>
        end
    end

    % ================= 3. EMG =================
    emgOK = isfile(matF);
    if ~emgOK
        issues(end+1,:) = add(s,k,'EMG','no EMG file - trial produces no EMG outcome'); %#ok<AGROW>
        for c = 1:numel(CH)
            chRows(end+1,:) = {k,s,string(CHNAME{c}),NaN,NaN,0,"no EMG file"}; %#ok<AGROW>
        end
    else
        S  = load(matF,'EMG');
        e0 = double(S.EMG.Epoch_ns(1)); e1 = double(S.EMG.Epoch_ns(end));
        if isfile(igF)
            cov = 100*(min(ts(end),e1)-max(ts(1),e0))/(ts(end)-ts(1));
            if cov < THR.emg_cov
                issues(end+1,:) = add(s,k,'EMG',sprintf('EMG covers only %.0f%% of the trial',cov)); %#ok<AGROW>
            end
        end
        fsE  = S.EMG.Frequencies.EMG;
        dead = []; if isfield(S.EMG,'DeadThisTrial'), dead = S.EMG.DeadThisTrial; end

        % bout in EMG-file seconds, trimmed
        if haveGyro
            st = (boutE(1)-e0)*1e-9 + TRIM;
            sp = (boutE(2)-e0)*1e-9 - TRIM;
        else
            st = -Inf; sp = Inf;
        end
        sp = min(sp, (e1-e0)*1e-9 - TRIM);      % never past the end of the EMG

        for c = 1:numel(CH)
            ch = CH(c); nm = CHNAME{c};
            if ismember(ch, dead)
                chRows(end+1,:) = {k,s,string(nm),NaN,NaN,0,"dead"}; %#ok<AGROW>
                issues(end+1,:) = add(s,k,'SENSOR',sprintf('%s sensor absent for the whole trial',nm)); %#ok<AGROW>
                continue;
            end
            env = S.EMG.Norm(:,ch);
            e   = (ev.(CHSIDE{c}) - e0)*1e-9;   % cycle triggers in EMG time
            e   = e(e >= st & e <= sp);
            Mx  = [];
            for q = 1:numel(e)-1
                a = e(q); b = e(q+1);
                if b-a < 0.6 || b-a > 1.8, continue; end
                i1x = round(a*fsE)+1; i2x = round(b*fsE);
                if i1x < 1 || i2x > numel(env), continue; end
                seg = env(i1x:i2x);
                if numel(seg) < 50 || any(isnan(seg)), continue; end
                Mx(end+1,:) = interp1(linspace(0,1,numel(seg)), seg, linspace(0,1,100)); %#ok<AGROW>
            end
            if size(Mx,1) < 15
                chRows(end+1,:) = {k,s,string(nm),NaN,NaN,size(Mx,1),"too few cycles"}; %#ok<AGROW>
                issues(end+1,:) = add(s,k,'EMG',sprintf('%s: only %d usable gait cycles - no burst depth computed',nm,size(Mx,1))); %#ok<AGROW>
                continue;
            end
            mu    = mean(Mx,1);
            depth = max(mu)/prctile(mu,10);
            vr    = sum(sum((Mx-mu).^2)) / sum(sum((Mx-mean(Mx(:))).^2));
            if     depth >= THR.burst_marg, flag = "OK";
            elseif depth >= THR.burst_low,  flag = "MARGINAL";
            else,                           flag = "LOW_MODULATION";
            end
            chRows(end+1,:) = {k,s,string(nm),depth,vr,size(Mx,1),flag}; %#ok<AGROW>
            if depth < THR.burst_low
                issues(end+1,:) = add(s,k,'EMG',sprintf(['%s: burst depth %.2f - envelope is nearly flat across the ' ...
                    'step cycle, so this channel probably records interference rather than muscle'],nm,depth)); %#ok<AGROW>
            end
            if size(Mx,1) < THR.min_cycles
                issues(end+1,:) = add(s,k,'EMG',sprintf('%s: %d gait cycles only',nm,size(Mx,1))); %#ok<AGROW>
            end
        end
    end

    trRows(end+1,:) = {k, s, string(M.condition(i)), fsIG, bout_s, cov, ...
        ncon(1), ncon(2), duty(1), duty(2), cad(1), cad(2), pausefrac, ...
        span(1), span(2), arange(1), arange(2)}; %#ok<AGROW>
end

% ===== tables =====
Tc = cell2table(chRows,'VariableNames',{'trial','session','channel', ...
        'burst_depth','variance_ratio','n_cycles','flag'});
Tt = cell2table(trRows,'VariableNames',{'trial','session','condition','fs_ingait_hz', ...
        'bout_s','emg_coverage_pct','n_contacts_L','n_contacts_R','duty_L_pct','duty_R_pct', ...
        'cadence_L_spm','cadence_R_spm','pause_pct','fsr_span_L','fsr_span_R', ...
        'angle_range_L','angle_range_R'});
writetable(Tc, fullfile(OutFolder,sprintf('QC_CHANNELS_%s.csv',participant)));
writetable(Tt, fullfile(OutFolder,sprintf('QC_TRIALS_%s.csv',participant)));

% ===== issue log =====
logF = fullfile(OutFolder,sprintf('ISSUES_%s.txt',participant));
fid  = fopen(logF,'w');
fprintf(fid,'DATA QUALITY LOG - participant %s\n', participant);
fprintf(fid,'Generated %s by s1e_QualityLog v3.\n', datestr(now));
fprintf(fid,['\nNOTHING BELOW HAS BEEN EXCLUDED. Every trial is processed by the\n' ...
             'pipeline. This log records what to weigh at the final analysis and\n' ...
             'what to declare in the limitations section.\n']);
fprintf(fid,'\nThe walking bout is taken from the gyro, which is independent of the\n');
fprintf(fid,'force and EMG signals being assessed. All metrics are computed inside it.\n');
fprintf(fid,'\nThresholds applied (identical for every participant):\n');
fprintf(fid,'  burst depth < %.1f | EMG coverage < %d%% | EMG cycles < %d\n', ...
        THR.burst_low, THR.emg_cov, THR.min_cycles);
fprintf(fid,'  FSR contacts < %d per foot | forefoot contact outside %d-%d%% of stride\n', ...
        THR.min_contacts, THR.duty_lo, THR.duty_hi);
fprintf(fid,'  left-right cadence differing by > %d steps/min | FSR range < %d counts\n', ...
        THR.cad_mismatch, THR.fsr_span);
fprintf(fid,'  ankle angle range < %.1f deg (checked on side: %s) | pauses > %d%%\n', ...
        THR.angle_span, strjoin(upper(gonioSides),','), THR.pause_frac);
fprintf(fid,'  inGAIT rate < %d Hz | bout < %d s\n', THR.fs_ingait, THR.min_bout);
fprintf(fid,'%s\n', repmat('=',1,74));

if isempty(issues)
    fprintf(fid,'\nNo thresholds crossed.\n');
else
    sess = cell2mat(issues(:,1));
    for s = unique(sess)'
        idx = find(sess == s);
        fprintf(fid,'\nSESSION %d  (%d entries)\n%s\n', s, numel(idx), repmat('-',1,74));
        for j = idx'
            fprintf(fid,'  trial %-3d [%-7s] %s\n', issues{j,2}, issues{j,3}, issues{j,4});
        end
    end
    fprintf(fid,'\n%s\nEntries per session:\n', repmat('=',1,74));
    for s = unique(sess)'
        fprintf(fid,'  session %-3d %d\n', s, nnz(sess==s));
    end
end
fclose(fid);

fprintf('\n=== DONE ===\n');
fprintf('  %s\n', fullfile(OutFolder,sprintf('QC_CHANNELS_%s.csv',participant)));
fprintf('  %s\n', fullfile(OutFolder,sprintf('QC_TRIALS_%s.csv',participant)));
fprintf('  %s   <- read this one\n', logF);
if ~isempty(issues)
    fprintf('\n%d entries across %d sessions. Nothing excluded.\n', ...
            size(issues,1), numel(unique(cell2mat(issues(:,1)))));
end
