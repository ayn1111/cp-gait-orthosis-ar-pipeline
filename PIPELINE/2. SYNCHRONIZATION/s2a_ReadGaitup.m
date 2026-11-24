% s2a_ReadGaitup.m
% =========================================================================
% STAGE 2, STEP 1 of 3.
%
% WHAT THIS PROCESSES
%   RAW\gaitup\<YYYYMMDD>\LF\*.bin  and  \RF\*.BIN   (60 files, 30 pairs)
%   PROCESSED\TRIALMAP_<P>.csv      (says which BIN belongs to which trial)
%
% WHAT IT ACHIEVES
%   PROCESSED\GAITUP\GAITUP_<P>_trial<k>.mat, one per trial, each containing:
%       GAITUP.Acc_l, GAITUP.Gyr_l    left foot   [N x 4], col 4 = device time
%       GAITUP.Acc_r, GAITUP.Gyr_r    right foot
%       GAITUP.src_l, GAITUP.src_r    source filenames, for traceability
%       GAITUP.dur_l, GAITUP.dur_r    durations, for the pairing check
%   Time is still on the GAITUP DEVICE CLOCK here. s2b aligns it to ROS.
%
% WHY THIS REPLACES a_Read_BIN.m
%   a_Read_BIN required you to rename all 60 files by hand to
%   LF_<P>_trial_<k>.BIN after pairing them yourself by file size. That is
%   error-prone and it would have gone wrong on this participant: on
%   25 Aug the right unit's counter rolled over from 99 to 01, so 01RF0466
%   sorts first but was recorded LAST. Pairing LF[i] with RF[i] would have put
%   trial 6's right foot with trial 4's left foot, and both files are ~300 s
%   so nothing would have looked wrong. The trial map already encodes the
%   correct pairing, so this script just reads what it is told.
%
% CHECK IT PERFORMS
%   LF and RF of a pair were started and stopped together, so their durations
%   must match. Anything over TOL_PAIR seconds apart means the trial map is
%   wrong for that trial, and the script says so loudly.
%
% RUNTIME: ~3-5 minutes for 60 files.
% =========================================================================

clear; clc;

% ===== USER SETTINGS =====
participant = 'CP03';
Root        = 'C:\INVESTIGACION CSIC\PAC03';
TrialMapCsv = fullfile(Root,'PROCESSED',sprintf('TRIALMAP_%s.csv',participant));
GaitupRoot  = fullfile(Root,'RAW','gaitup');
SaveFolder  = fullfile(Root,'PROCESSED','GAITUP');
physilogToolkitPath = ['C:\INVESTIGACION CSIC\Data analysis\2. Synchronization\' ...
                       'Physilog5MatlabToolkit_v1_5_3_compatibleP6'];

TOL_PAIR = 3.0;    % s; max allowed LF/RF duration difference within a pair
% =========================

if exist(physilogToolkitPath,'dir'), addpath(physilogToolkitPath); end
if ~exist('ReadLogFile_Physilog6','file')
    error('ReadLogFile_Physilog6 not found. Fix physilogToolkitPath.');
end
if ~exist(SaveFolder,'dir'), mkdir(SaveFolder); end

M  = loadTrialMap(TrialMapCsv);   % forces gaitup_day to text; see loadTrialMap.m
nT = height(M);

fprintf('%-3s %-3s %-10s %-16s %8s   %-16s %8s   %s\n', ...
        'tr','S','day','LF file','dur_L','RF file','dur_R','pair');
fprintf('%s\n', repmat('-',1,92));

nBad = 0; nDone = 0; nMissing = 0;
for i = 1:nT
    k   = M.trial(i);
    day = asText(M.gaitup_day(i));
    lfN = asText(M.gaitup_LF(i));
    rfN = asText(M.gaitup_RF(i));

    % A day folder that does not exist means the trial map or the raw tree is
    % wrong. Say so once per trial rather than twice per foot.
    dayDir = fullfile(GaitupRoot, day);
    if ~exist(dayDir,'dir')
        fprintf('%-3d %-3d %-10s   *** day folder not found: %s ***\n', k, M.session(i), day, dayDir);
        nMissing = nMissing + 1;
        continue;
    end

    GAITUP = struct();
    durL = NaN; durR = NaN;

    % ---- LEFT ----
    lf = pickFile(fullfile(GaitupRoot, day, 'LF'), lfN);
    if isempty(lf)
        warning('Trial %d: LEFT file %s not found under %s', k, lfN, fullfile(GaitupRoot,day,'LF'));
    else
        try
            [Acc_l, Gyr_l] = ReadLogFile_Physilog6(lf);
            GAITUP.Acc_l = Acc_l;  GAITUP.Gyr_l = Gyr_l;
            GAITUP.src_l = lfN;
            durL = spanOf(Acc_l);
        catch ME
            warning('Trial %d: error reading LEFT %s: %s', k, lf, ME.message);
        end
    end

    % ---- RIGHT ----
    rf = pickFile(fullfile(GaitupRoot, day, 'RF'), rfN);
    if isempty(rf)
        warning('Trial %d: RIGHT file %s not found under %s', k, rfN, fullfile(GaitupRoot,day,'RF'));
    else
        try
            [Acc_r, Gyr_r] = ReadLogFile_Physilog6(rf);
            GAITUP.Acc_r = Acc_r;  GAITUP.Gyr_r = Gyr_r;
            GAITUP.src_r = rfN;
            durR = spanOf(Acc_r);
        catch ME
            warning('Trial %d: error reading RIGHT %s: %s', k, rf, ME.message);
        end
    end

    if ~isfield(GAITUP,'Acc_l') && ~isfield(GAITUP,'Acc_r')
        fprintf('%-3d %-3d %-10s   *** no GaitUp data for this trial ***\n', k, M.session(i), day);
        continue;
    end

    % ---- pairing check ----
    verdict = 'ok';
    if isfinite(durL) && isfinite(durR)
        if abs(durL-durR) > TOL_PAIR
            verdict = sprintf('MISMATCH %.1f s', abs(durL-durR));
            nBad = nBad + 1;
        end
    else
        verdict = 'one side only';
    end

    GAITUP.dur_l = durL;  GAITUP.dur_r = durR;
    GAITUP.trial = k;     GAITUP.session = M.session(i);
    GAITUP.day   = day;

    fprintf('%-3d %-3d %-10s %-16s %8.1f   %-16s %8.1f   %s\n', ...
            k, M.session(i), day, lfN, durL, rfN, durR, verdict);

    save(fullfile(SaveFolder, sprintf('GAITUP_%s_trial%d.mat', participant, k)), 'GAITUP');
    nDone = nDone + 1;
end

fprintf('\n=== DONE ===\n');
fprintf('%d of %d trials written to %s\n', nDone, nT, SaveFolder);

if nDone == 0
    error(['s2a wrote NOTHING. Nothing was read, so nothing was checked and no\n' ...
           'conclusion below would have meant anything.\n\n' ...
           'Most likely causes, in order:\n' ...
           '  1. GaitupRoot does not point at the folder holding the day folders.\n' ...
           '     Expected: %s\\<YYYYMMDD>\\LF\\*.bin\n' ...
           '  2. loadTrialMap.m is not on the MATLAB path, so gaitup_day imported\n' ...
           '     as a number and every path was built from a garbage character.\n' ...
           '  3. The day folder names in the trial map do not match the raw tree.'], GaitupRoot);
end
if nMissing > 0
    fprintf('%d trial(s) had no day folder at all.\n', nMissing);
end
if nBad > 0
    fprintf(['\n*** %d trial(s) have LF/RF durations more than %.1f s apart. ***\n' ...
             'The two units are started and stopped together, so a mismatch means\n' ...
             'the trial map pairs the wrong files. Fix TRIALMAP before continuing -\n' ...
             'a wrong pairing puts one foot of one trial with the other foot of a\n' ...
             'different trial, and every downstream number will look plausible.\n'], nBad, TOL_PAIR);
else
    fprintf('All %d pairs read agree in duration. Pairing confirmed.\n', nDone);
end
fprintf('\nNEXT: s2b_AlignGaitup_CP03.m\n');

% ===== helpers =====
function t = asText(v)
% Trial-map values must reach fullfile() as text. A numeric-looking identifier
% such as 20260824 imported as a double becomes a garbage character under
% char(), so convert explicitly rather than trusting the import type.
    if isstring(v) || ischar(v)
        t = char(v);
    elseif isnumeric(v)
        t = char(string(v));            % 20260824 -> "20260824"
    else
        t = char(string(v));
    end
end

function f = pickFile(folder, name)
% Case-insensitive lookup: the left unit writes .bin, the right writes .BIN.
    f = '';
    if ~exist(folder,'dir'), return; end
    d = dir(folder);
    d = d(~[d.isdir]);
    hit = find(strcmpi({d.name}, name), 1);
    if ~isempty(hit), f = fullfile(d(hit).folder, d(hit).name); end
end

function s = spanOf(A)
% Duration of a Physilog channel. Numeric layout is [x y z t].
    s = NaN;
    if isnumeric(A) && size(A,2) >= 4
        t = double(A(:,4)); s = t(end)-t(1);
    elseif isstruct(A) && isfield(A,'t')
        t = double(A.t(:)); s = t(end)-t(1);
    end
end
