% s0b_ListGaitupDurations.m — read every GaitUp BIN and report its true duration.
%
% Purpose: the GaitUp device clocks were never set (headers read 1970), so file
% start times are useless. Duration is the only intrinsic property that lets us
% check the BIN -> trial assignment, and session 1 has 5 recordings for 3 trials.
%
% This script reads only. It writes nothing except a CSV listing.
% Expected runtime: a couple of minutes for 64 files.

clear; clc;

% ===== SETTINGS — edit these two paths only =====
raw_root            = 'C:\INVESTIGACION CSIC\PAC03\RAW\gaitup';
physilogToolkitPath = 'C:\INVESTIGACION CSIC\Data analysis\2. Synchronization\Physilog5MatlabToolkit_v1_5_3_compatibleP6';
outCsv              = 'C:\INVESTIGACION CSIC\PAC03\PROCESSED\GAITUP_DURATIONS.csv';
% ================================================

if exist(physilogToolkitPath,'dir'), addpath(physilogToolkitPath); end
if ~exist('ReadLogFile_Physilog6','file')
    error('ReadLogFile_Physilog6 not found. Fix physilogToolkitPath.');
end
outDir = fileparts(outCsv);
if ~isempty(outDir) && ~exist(outDir,'dir'), mkdir(outDir); end

days = dir(fullfile(raw_root, '2026*'));
days = days([days.isdir]);
if isempty(days), error('No day folders (2026*) found in %s', raw_root); end

rows = {};
fprintf('%-10s %-4s %-4s %-16s %10s %10s\n', 'day','side','idx','file','dur_s','n_samples');
fprintf('%s\n', repmat('-',1,62));

for d = 1:numel(days)
    day = days(d).name;
    for sd = {'LF','RF'}
        side = sd{1};
        folder = fullfile(raw_root, day, side);
        if ~exist(folder,'dir')
            warning('Missing folder: %s', folder); continue;
        end
        F = dir(fullfile(folder, '*.*'));
        F = F(~[F.isdir]);
        keep = false(numel(F),1);
        for i = 1:numel(F)
            [~,~,ext] = fileparts(F(i).name);
            keep(i) = strcmpi(ext, '.bin');
        end
        F = F(keep);
        [~,ord] = sort(upper({F.name}));   % device numbering = chronological
        F = F(ord);

        for i = 1:numel(F)
            p = fullfile(F(i).folder, F(i).name);
            dur = NaN; ns = NaN;
            try
                [Acc, ~] = ReadLogFile_Physilog6(p);
                if isnumeric(Acc)
                    t = double(Acc(:,4));
                elseif isstruct(Acc) && isfield(Acc,'t')
                    t = double(Acc.t(:));
                else
                    t = [];
                end
                if ~isempty(t)
                    dur = t(end) - t(1);
                    ns  = numel(t);
                end
            catch ME
                warning('Failed to read %s: %s', p, ME.message);
            end
            fprintf('%-10s %-4s %-4d %-16s %10.1f %10d\n', day, side, i, F(i).name, dur, ns);
            rows(end+1,:) = {day, side, i, F(i).name, dur, ns}; %#ok<AGROW>
        end
    end
end

T = cell2table(rows, 'VariableNames', {'day','side','idx','file','dur_s','n_samples'});
writetable(T, outCsv);
fprintf('\nSaved -> %s\n', outCsv);
fprintf('\nWHAT TO CHECK:\n');
fprintf('  1. Within each day, LF(i) and RF(i) durations should match within ~1 s.\n');
fprintf('  2. Session 1 (20260824) has 5 recordings for 3 trials. The three real\n');
fprintf('     trials should be noticeably longer than the two discarded ones.\n');
fprintf('  3. Every duration should exceed the matching inGAIT trial duration,\n');
fprintf('     since GaitUp is started before and stopped after the walk.\n');
