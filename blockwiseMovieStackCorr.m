function [xyzrcoPeak, params] = blockwiseMovieStackCorr(subj, movieDate, varargin)
% function [xyzrcoPeak, params] = blockwiseMovieStackCorr(subj, movieDate, varargin)
%
% Register each frame of the motion-corrected movie to reference z-stack by finding
% the x, y, z position and rotation angle (r) that maximize correlations between (36)
% partially overlapping blocks from the movie and the slices of the stack. For first 
% frame, search through many possibilities to define a neighborhood to search within 
% for final registrations. After each frame is registered, update this search range 
% prior for the next frame. When a block's values are incongruent with its neighbors 
% it is marked as an oddball. If it doesn't have a clear peak correlation, the 
% center of its search range is used and the correlation is marked as nan.
% 
%
% inputs:
% subj          - mouse ID (e.g., J115)
% movieDate     - date of movie to register (e.g., 2015-09-25)
%
% output variables:
% xyzrcoPeak    - 6 x nBlocks x nFrames matrix containing the x, y, z position, 
%                 rotation angle, correlation value, and oddball status of each 
%                 block's best registration for each frame
% params        - the parameters used to generate the alignment
% 
% ouput files:
% summary      - unless the optional 'summarySaveName' is supplied as empty, 
%                running this function will create a directory 
%                <subj>/<movieDate>/<location>_referenceLocalization 
%                and write a file called summary.mat containing the xyzrcoPeak, 
%                params, xyzrSearchRange and other fields. See intaglio document
%                for more information.
% block        - unless the optional 'blockSaveFormat' is supplied as empty
%                running this function will create a frameXXX/blockXXX.mat file
%                within the reference localization folder. It will contain an array 
%                of correlation values and indices for their corresponding x, y, z, r
%                positions. The createPairsPlot function can be used to build sparse 
%                matrices from these values and turn them into useful visualizations.
% searchRange -  unless 'searchRangeFigName' is supplied as empty, running this function
%                will produce a pdf showing the x,y,z,r values and outliers for the 
%                initial search range 
%
% Some important optional arguments:
% showFigs      - default 'off'; determines whether search range figures should pop up
%                 while code is running
% mByNBlocks    - default [6 6]; determines how many blocks to tile image
% blockOverlap  - default 10; determines how much overlap blocks should have 
%                 (treated as percentage of block if < 1)
% whichBlocks   - default 1:nBlocks; which of the blocks to register
% whichFrames   - default 1:nFrames; which of the frames to register
% whichSlices   - default 1:nSlices; which of the z slices to consider for registration
%
% nbrhdXMargin  - Numer of pixels around searchRange x center to compute correlation
%                 values for. This helps avoid picked spurious correlations by 
%                 by keeping the block on a "leash" in x. 
% minCorrOverlap 
%               - Minimum amount of overlap required between block and stack for 
%                 registration.
% 
% coarseRotStepSz 
%               - granularity of rotation angle search for searchRange
% fineRotStepSz - granularity of rotation angle search around final neighborhood
%
% nZToKeepInlier
%               - Number of z values to use for the neighborhood around inliers
% nZToKeepOutlier 
%               - Number of z values to use for the neighborhood around outliers/oddballs
% 
% flagZNFromEdge 
%               - Default 2. If best z is found to be within this number of the min or max of 
%                 z values to consider, then label as an oddball AND open up the range of z 
%                 values to consider until you have found a good match that is not close to 
%                 the edge of the window or until the window can't grow anymore. There is a 
% flagRNFromEdge
%               - equivalent of flagZNFromEdge, but for rotaions.
%
% nXYToKeep     - Number of correlation values to keep in block-specific .mat files
% corrType      - format for storing correlation values in block-specific .mat files
%
% useXYSearchRangeFromDate
%               - Defaults to empty, but if a date is supplied, the searchRange from that
%                 date will be used to constrain the x,y positions for the calculation of 
%                 the current searchRange
%
% searchRangeXMargin
%               - Similar to nbrhdXMargin, expect specific to finding the initial searchRange
% nRSTD         - Defaults to 8, which is too high. Number of robust standard deviations
%                 beyond which points are considered outliers in computing the search range.
% xRadiusMin    - The max of this value and nRSTD * RSTD is used for determining outliers 
%                 in the search range
%

% ---------- parse optional inputs ---------- %
%
p = inputParser;

addParameter(p,'summarySaveName', 'summary.mat',@isstr);
addParameter(p,'blockSaveFormat', 'block%03i.mat',@isstr);

addParameter(p, 'location','L01');
addParameter(p, 'stackDate', []);

% can pass in already loaded stack and movie, but BEWARE saved path names will 
% get out of sync with real movie/stack if you pass in the wrong ones!!
addParameter(p,'loadedStack',[],@isnumeric);
addParameter(p,'loadedMovie',[],@isnumeric);

addParameter(p,'dataDir',[],@(x) isdir(x) | isempty(x));

addParameter(p,'corrType', 'uint16', @(x) ismember(x,{'uint8','uint16','uint32','uint64','double'}));
addParameter(p,'nXYToKeep', 400, @(x) isnumeric(x) & ~mod(x,1));

addParameter(p,'mByNBlocks',[6 6],@(x) isnumeric(x) & ~mod(x,1));
addParameter(p,'blockOverlap',10,@(x) ispositive(x) & isnumeric(x));

addParameter(p,'whichBlocks', [],@isnumeric);
addParameter(p,'whichFrames', [],@isnumeric);
addParameter(p,'whichSlices', [],@isnumeric);

addParameter(p,'coarseRotStepSz',.5, @(x) ispositive(x) & isnumeric(x));
addParameter(p,'coarseRotWindowRange',20, @(x) ispositive(x) & isnumeric(x));

if strcmp(subj,'J114')
    addParameter(p,'fineRotWindowRange',10, @(x) ispositive(x) & isnumeric(x));
    addParameter(p,'fineRotStepSz',.5, @(x) ispositive(x) & isnumeric(x));
    
else
    addParameter(p,'fineRotWindowRange',6, @(x) ispositive(x) & isnumeric(x));
    addParameter(p,'fineRotStepSz',.25, @(x) ispositive(x) & isnumeric(x));
    
end

addParameter(p,'nZToKeepInlier', 11, @(x) isnumeric(x) & mod(x,2) == 1);
addParameter(p,'nZToKeepOutlier', 21, @(x) isnumeric(x) & mod(x,2) == 1);

addParameter(p,'angleSigFig',2,@(x) isnumeric(x) & ~mod(x,1));

% gets used as savename in separate functin fitXYZRSearchRange
addParameter(p, 'searchRangeFigName','searchRangeFig.pdf');

addParameter(p,'inferZWindow',100,@(x) isnumeric & ~mod(x,1));  % inferZWindow is only relevant if useZFit
addParameter(p,'zFitPower',5,@(x) isnumeric(x) & ~mod(x,1));
addParameter(p,'rFitPower',4,@(x) isnumeric & ~mod(x,1));
addParameter(p, 'rFitFigName','rFit.pdf'); % automatically saves fit figure in frame001
addParameter(p, 'zFitFigName' ,'zFit.pdf');
addParameter(p, 'zSearchRangeUseFit', false, @islogical)
addParameter(p, 'rSearchRangeUseFit', false, @islogical)

addParameter(p,'showFigs','off',@(x) any(strcmp({'on','off'},x)));

addParameter(p, 'useSavedSearchRange', true, @islogical);
addParameter(p, 'useSavedSearchRangeEitherWay', false, @islogical);

addParameter(p, 'nbrhdXMargin', 10, @isnumeric);
addParameter(p, 'nbrhdYMargin', 10, @isnumeric);
addParameter(p, 'minCorrOverlap', .8, @isnumeric);

addParameter(p, 'useXYSearchRangeFromDate', []);
addParameter(p, 'searchRangeXMargin', 50, @isnumeric);
addParameter(p, 'searchRangeYMargin', 50, @isnumeric);



% for defining outliers when setting up search range
addParameter(p, 'nRSTD', 8)
addParameter(p,'xRadiusMin',4,@isnumeric);
addParameter(p,'yRadiusMin',4,@isnumeric);

% will flag as oddballs if alignment is found this close to 
% edge of possible z's or r's. If possible, will expand the
% neighborhood to include more zs or rs.
addParameter(p, 'flagZNFromEdge', 2)
addParameter(p, 'flagRNFromEdge', 2)






%addParameter(p,'saveName','',@isstr);

p.KeepUnmatched = true;

parse(p,varargin{:})
% ----------------------------------------- %

fprintf('\nstarting registration for subj: %s on movie from %s \n',subj, movieDate);
% reassign p.Results to params and get rid of p so it is easier to manage
% subfields
if ~isempty(fields(p.Unmatched))
    warning(sprintf('unmatched fields in input: \n\t%s\n', strjoin(fields(p.Unmatched),'\n\t')));
end
params = p.Results;
clear p;

% check that a folder for this movie date exists
if ~exist(fullfile(jlgDataDir,subj,movieDate,params.location),'file')
    error('There is no folder for this date and subject');
end

params.subj = subj;
params.movieDate = movieDate;
if isempty(params.dataDir)
    params.dataDir = jlgDataDir;
end

nbrhdInf = struct('xMargin', params.nbrhdXMargin, 'yMargin', params.nbrhdYMargin);
nbrhdInf.minOverlap = params.minCorrOverlap;
nbrhdInf.flagZNFromEdge = params.flagZNFromEdge;

% if only one number is given for mByNBlocks, repeat it for both dimensions
if size(params.mByNBlocks) == 1, params.mByNBlocks = repmat(params.mByNBlocks, 1, 2); end
params.nBlocks = prod(params.mByNBlocks);

if (params.nbrhdYMargin+1)*2 * (params.nbrhdXMargin+1)*2 < params.nXYToKeep,
    params.nXYToKeep = (params.nbrhdYMargin+1)*2 * (params.nbrhdXMargin+1)*2;
end

set(0, 'DefaultFigureVisible', params.showFigs);

% date information to save
dateStr = datestr(now);
dateNum = now;

% assemble some variables based on optional input parameters
params.coarseRotAngles  = -(params.coarseRotWindowRange/2):params.coarseRotStepSz:(params.coarseRotWindowRange/2);
params.coarseRotAngles = round(params.coarseRotAngles, params.angleSigFig);
% remove instances of coarseRotAngle == 0 because this will have higher
% correlation than the other angles and screw up our fit
params.coarseRotAngles(params.coarseRotAngles == 0) = [];
fineRotAngles          = -(params.fineRotWindowRange/2): params.fineRotStepSz ...
    :(params.fineRotWindowRange/2);
fineRotAngles          = round(fineRotAngles, params.angleSigFig);
rotAngleFromInd        = params.coarseRotAngles(1):params.fineRotStepSz ...
    :params.coarseRotAngles(end);
rotAngleFromInd        = round(rotAngleFromInd, params.angleSigFig);
params.rotAngleFromInd = rotAngleFromInd;
assert(length(params.rotAngleFromInd) <= 255); % make sure that we can represent rotation with uint8


nbrhdInf.rOffToKeep    = fineRotAngles;


% load stack
movieFname = sprintf('%s__%s__AVERAGE.tif',movieDate,params.location);
if isempty(params.stackDate),
    params.stackDate =  defaultStackDate(subj);
end

% enforce that stack and movie have same zoom factor
movHdrFile = fullfile(jlgDataDir,subj,movieDate,params.location,'ac_001_001.tif');
stackHdrDirs = dir(fullfile(jlgDataDir, subj, params.stackDate, 'post*stack*'));
if ismember('post_stack',{stackHdrDirs.name})
    stackHdrDir = 'post_stack';
elseif ismember('post-stack',{stackHdrDirs.name})
    stackHdrDir = 'post-stack';
elseif ismember('post_stack_001',{stackHdrDirs.name})
    stackHdrDir = 'post_stack_001';
end
stackHdrFile = fullfile(jlgDataDir, subj, params.stackDate, stackHdrDir,'post_stack_001_001.tif');
%get image headers
stackHdr = getScanImageHeader(stackHdrFile); movHdr = getScanImageHeader(movHdrFile);
if ~(stackHdr.scanimage.SI5.zoomFactor == movHdr.scanimage.SI5.zoomFactor)
    error('Stack and movie have different zoom factors');
end

% load stack
stackPath = fullfile(subj, sprintf('reference_stack_%s.tif',params.stackDate));
fullStackPath = fullfile(params.dataDir, stackPath);
moviePath = fullfile(subj, movieFname);
fullMoviePath = fullfile(params.dataDir, moviePath);
assert(exist(fullMoviePath,'file') & exist(fullStackPath,'file'));
stackInf  = imfinfo(fullStackPath);
stackDim.depth = length(stackInf);
if ~isempty(params.loadedStack)
    stack = params.loadedStack;
else
    stack = zeros(stackInf(1).Height,stackInf(1).Width,stackDim.depth);
    for ss = 1:length(imfinfo(fullStackPath))
        stack(:,:,ss) = imread(fullStackPath,ss);
    end
end
rmfield(params,'loadedStack');

% load movie
movieInf = imfinfo(fullMoviePath);
movieHeight = movieInf(1).Height;
movieWidth  = movieInf(1).Width;
movieLength = length(movieInf);
if ~isempty(params.loadedMovie)
    movie = params.loadedMovie;
else
    movie = zeros(movieHeight,movieWidth,movieLength);
    for mm = 1:length(imfinfo(fullMoviePath))
        movie(:,:,mm) = imread(fullMoviePath,mm);
    end
end
rmfield(params,'loadedMovie');

% check stack and movie size matches file dimensions
assert(isequal([stackInf(1).Height, stackInf(1).Width, stackDim.depth], size(stack)));
assert(isequal([movieHeight, movieWidth, movieLength], size(movie)));

% crop dark edge off stack by removing rows of all zero entries and get new
% size
stack = cropStack(stack);
[stackDim.height, stackDim.width, stackDim.depth] = size(stack);

% create correlations directory
assert(fullMoviePath(end-3)=='.');
movieDate = movieFname(1:10);
movieDateDir = fullfile(params.dataDir, subj, movieDate);
params.corrDir = referenceLocalizationDir(subj, movieDate, params.location);

if ~exist(movieDateDir, 'dir'), mkdir(movieDateDir); end
if ~exist(params.corrDir, 'dir'), mkdir(params.corrDir); end

if isempty(params.whichBlocks), params.whichBlocks = 1:params.nBlocks; end
if isempty(params.whichFrames), params.whichFrames = 1:movieLength; end
if isempty(params.whichSlices), params.whichSlices = 1:stackDim.depth; end


% divide movie into blocks based on the movie dimensions, desired number of
% blocks, percent overlap between blocks, and maximum amount of rotation
% (used to create a margin)
blockLocations = makeBlockLocations(movieHeight, movieWidth, ...
    params.mByNBlocks, params.blockOverlap, max(params.coarseRotAngles));

% initialize matrix to store peak of correlations
xyzrcoPeak = zeros(6,params.nBlocks,movieLength);
xyzrSearchRange = zeros(5,params.nBlocks);

% check is a summary file exists for this analysis and make one if it
% doesn't
if ~isempty(params.summarySaveName)
    summaryPath = fullfile(params.corrDir, params.summarySaveName);
    if exist(summaryPath,'file')
        % if the file exists, append to it so that we keep the search range
        save(summaryPath,'xyzrcoPeak', 'blockLocations','rotAngleFromInd',...
            'stackPath','moviePath','dateStr', 'dateNum','params','stackDim',...
            '-append');
    else
        save(summaryPath,'xyzrcoPeak', 'blockLocations','rotAngleFromInd',...
            'stackPath','moviePath','dateStr', 'dateNum','params','stackDim');
    end
    summfile = matfile(summaryPath,'writable',true);
end


% ------ iterate through the frames of the movie ------ %
for ff = 1:length(params.whichFrames),
    
    % select the relevant movie frame and the relevant block
    thisFrameNo = params.whichFrames(ff);
    movieFrame = movie(:,:,thisFrameNo);
    frameString = sprintf('frame: %03i/%03i',thisFrameNo,movieLength);
    disp(frameString);
    
    % create a directory to store outputs for this frame
    params.frameCorrDir = fullfile(params.corrDir, sprintf('frame%03i', thisFrameNo));
    if ~exist(params.frameCorrDir, 'dir')
        mkdir(params.frameCorrDir);
    end
    
    if ff == 1
        [xyzrSearchRange, outliersXY] = getSearchRange(movieFrame, ...
            blockLocations, stack, nbrhdInf, params);
    end
    
    % ----------------- iterate through the blocks to keep values ------------------- %
    for bb = 1:length(params.whichBlocks)
        % select the relevant block location matrix and get its dimensions so
        % we can determine how many values will be in the correlation matrix
        thisBlockNo   = params.whichBlocks(bb);
        thisBlockLoc  = blockLocations(:,:,thisBlockNo);
        
        nbrhdInf.xCtr = xyzrSearchRange(1,thisBlockNo);
        nbrhdInf.yCtr = xyzrSearchRange(2,thisBlockNo);
        nbrhdInf.zCtr = xyzrSearchRange(3,thisBlockNo);
        nbrhdInf.rCtr = xyzrSearchRange(4,thisBlockNo); 
        if outliersXY(thisBlockNo)
            nbrhdInf.zOffToKeep    = -floor(params.nZToKeepOutlier/2):floor(params.nZToKeepOutlier/2);
        else
            nbrhdInf.zOffToKeep    = -floor(params.nZToKeepInlier/2):floor(params.nZToKeepInlier/2);
        end

        
        % Loop through the specified range of z values and angles
        fprintf('computing correlations in peak neighborhood for block %03i...\n',thisBlockNo);
        [thisXyzrcoPeak, blockCorrs] = localizeBlockInStackNbrhd(thisBlockLoc, ...
            movieFrame, stack, nbrhdInf, 'rotAngleFromInd', params.rotAngleFromInd,...
            'angleSigFig',params.angleSigFig, 'nXYToKeep',params.nXYToKeep,...
            'flagRNFromEdge',params.flagRNFromEdge, 'flagZNFromEdge', params.flagZNFromEdge,...
            'whichSlices', params.whichSlices,'fineRotStepSz', params.fineRotStepSz);
        
        % save absolute peak
        if ~isempty(thisXyzrcoPeak)
            xyzrcoPeak(:,thisBlockNo, thisFrameNo) = thisXyzrcoPeak;
            
        else % if no good peak found, use the center of the search range
            xyzrcoPeak(:, thisBlockNo, thisFrameNo) = [xyzrSearchRange(:,thisBlockNo); nan; 1];
            % round the x and y centers according to the dimensions of the
            % block. If the block dimension is even, the center should be at a
            % multiple of .5
            thisX = xyzrcoPeak(1, thisBlockNo, thisFrameNo);
            thisY = xyzrcoPeak(2, thisBlockNo, thisFrameNo);
            % if width is even, put x center at closest .5, else closest integer
            xyzrcoPeak(1, thisBlockNo, thisFrameNo) = round(thisX) + ~mod(bInf.width,2)*sign(thisX-round(thisX))*.5;
            % if height is even, put y center at closest .5, else closest integer
            xyzrcoPeak(2, thisBlockNo, thisFrameNo) = round(thisY) + ~mod(bInf.height,2)*sign(thisY-round(thisY))*.5;
        end
        
        if strcmp(params.corrType,'double')
            blockCorrs.corrValsToSave = cast(blockCorrs.corrValsToSave *...
                double(intmax(params.corrType)), params.corrType);
        end
        
        % save block-specific registration information
        if ~isempty(params.blockSaveFormat)
            blockFileName = fullfile(params.frameCorrDir, sprintf(params.blockSaveFormat,thisBlockNo));
            save(blockFileName, '-struct', 'blockCorrs');
            save(blockFileName, 'dateStr','dateNum', 'stackPath','rotAngleFromInd');
        end
    end
    
    % update the search range for the next frame and keep track of the
    % outliers for this frame
    [xyzrSearchRange, outliersXY] = fitXYZRSearchRange(xyzrcoPeak(1,:, thisFrameNo),xyzrcoPeak(2,:, thisFrameNo),...
        xyzrcoPeak(3,:, thisFrameNo), xyzrcoPeak(4,:, thisFrameNo), params);
    xyzrcoPeak(6,:, thisFrameNo) = xyzrcoPeak(6,:, thisFrameNo) | outliersXY;
    
    % write the results of this frame into the summary file
    if ~isempty(params.summarySaveName)
        summfile.xyzrcoPeak(:,:,thisFrameNo) = xyzrcoPeak(:,:,thisFrameNo);
    end
    
end

set(0, 'DefaultFigureVisible', 'on');

end













%%%%%%% END OF MAIN FUNCTION %%%%%%%%
%========================================================================%
%%%%%%% HELPER FUNCTIONS %%%%%%%%






function [xyzrSearchRange, outliersXY] = getSearchRange(movieFrame, blockLocations, stack, ...
    nbrhdInf, params)
% function [xyzrSearchRange] = getSearchRange(movieFrame, blockLocations, stack, ...
% nbrhdInf, params)


% x and y leash to use for setting z search range; only comes into play if
% the option useXYSearchRangeFromDate is set to true
initialNbrhdInf = nbrhdInf;
initialNbrhdInf.xMargin = params.searchRangeXMargin;
initialNbrhdInf.yMargin = params.searchRangeYMargin;

if ~isempty(params.useXYSearchRangeFromDate)
    prevSummaryFile = fullfile(referenceLocalizationDir(params.subj, ...
        params.useXYSearchRangeFromDate, params.location), params.summarySaveName);
    prevSearchRange = load(prevSummaryFile, 'xyzrSearchRange');
end

if ~isempty(params.summarySaveName)
    summaryPath = fullfile(params.corrDir, params.summarySaveName);
    % load the summary.mat file
    sfile = matfile(summaryPath, 'Writable',true);
    if ~ismember('params',fields(sfile))
        fprintf('Could not find xyzrSearchRange in summary.mat. Recomputing...');
    else
        savedParams = sfile.params;
        fprintf('Attempting to use saved searchRange...\n');
        hasSameParams = (isequal(savedParams.mByNBlocks, params.mByNBlocks) & isequal(savedParams.whichBlocks, params.whichBlocks) ...
            & isequal(savedParams.whichSlices, params.whichSlices) & savedParams.whichFrames(1) == params.whichFrames(1) ...
            & savedParams.inferZWindow == params.inferZWindow & (savedParams.zFitPower == params.zFitPower | params.zSearchRangeUseFit == 0) ...
            & savedParams.zSearchRangeUseFit == params.zSearchRangeUseFit &   (savedParams.rFitPower == params.rFitPower | params.rSearchRangeUseFit == 0)...
            & savedParams.rSearchRangeUseFit == params.rSearchRangeUseFit & isequal(savedParams.coarseRotAngles,params.coarseRotAngles) ...
            & isequal(savedParams.rotAngleFromInd,params.rotAngleFromInd) & params.nRSTD==savedParams.nRSTD & params.xRadiusMin==savedParams.xRadiusMin & ...
            params.yRadiusMin==savedParams.yRadiusMin);
        
        if (hasSameParams || params.useSavedSearchRangeEitherWay) && ...
                ismember('xyzrSearchRange',fields(sfile)) && ...
                ismember('outliersXY',fields(sfile))
            xyzrSearchRange = sfile.xyzrSearchRange;
            outliersXY      = sfile.outliersXY;
            return
        else
            fprintf('Parameters did not match previously computed . Recomputing...');
        end
    end
end


if ~isempty(params.zFitFigName)
    zFitFig = figure('Visible',params.showFigs);
    [~, zFitPlotMat] = makeSubplots(get(zFitFig,'Number'),params.mByNBlocks(2),params.mByNBlocks(1),.1,.1,[.05 .05 .95 .95]);
    linkaxes(zFitPlotMat(:));
end
if ~isempty(params.rFitFigName)
    rFitFig = figure('Visible',params.showFigs);
    [~, rFitPlotMat] = makeSubplots(get(rFitFig,'Number'),params.mByNBlocks(2),params.mByNBlocks(1),.1,.1,[.05 .05 .95 .95]);
    linkaxes(rFitPlotMat(:));
end

[stackDim.height, stackDim.width, stackDim.depth] = size(stack);


% ------------ get initial z  estimate for each block --------------- %
fprintf('getting initial searchRange on z for all blocks...\n');
bestZData    = nan(1,params.nBlocks);
bestZFit     = nan(1,params.nBlocks);
bestRData    = nan(1,params.nBlocks);
bestRFit     = nan(1,params.nBlocks);
bestXCtrData  = nan(1,params.nBlocks);
bestYCtrData  = nan(1,params.nBlocks);
bestCorrData  = nan(1,params.nBlocks);
bestXCtrDataRot = nan(1,params.nBlocks);
bestYCtrDataRot = nan(1,params.nBlocks);
blockHeights = nan(1,params.nBlocks);
blockWidths  = nan(1,params.nBlocks);

for bb = 1:length(params.whichBlocks)
    
    % select the relevant block location matrix and get its dimensions so
    % we can determine how many values will be in the correlation matrix
    thisBlockNo  = params.whichBlocks(bb);
    thisBlockLoc = blockLocations(:,:,thisBlockNo);
    bInf         = getBlockInf(thisBlockLoc);
    block        = movieFrame(bInf.indY,bInf.indX);
    
    if exist('prevSearchRange','var')
        initialNbrhdInf.xCtr = prevSearchRange.xyzrSearchRange(1,thisBlockNo);
        initialNbrhdInf.yCtr = prevSearchRange.xyzrSearchRange(2,thisBlockNo);
    else
        initialNbrhdInf.xCtr = [];
        initialNbrhdInf.yCtr = [];
    end
    
    fprintf('computing normxcorr2 for block %03i z estimate...\n',thisBlockNo);
    tic
    
    % matrix to fill to get best z for unrotated blocks
    frameCorrVolNoRot = zeros(bInf.height+stackDim.height-1,bInf.width+stackDim.width-1,...
        stackDim.depth);
    
    % look for best correlation with all slices of interest to set search
    % range
    for zz = 1:length(params.whichSlices),
        thisSliceNo = params.whichSlices(zz);
        stackSlice = stack(:,:,thisSliceNo);
        frameCorrVolNoRot(:,:,thisSliceNo) = computeBlockImageCorrs(block, ...
            stackSlice, initialNbrhdInf, 'double');
    end
    toc
    
    % find maximum correlation for each z and fit a polynomial to the
    % correlation values in a window around the max. Then choose z that
    % maximizes the fit curve
    
    maxCorrByZData = squeeze(max(max(frameCorrVolNoRot(:,:,:),[],1),[],2));
    % get position of upper left corner of block at best match
    [bestCorrData(thisBlockNo), maxInd]    = max(frameCorrVolNoRot(:));
    [bestYData, bestXData, bestZData(thisBlockNo)] = ind2sub(size(frameCorrVolNoRot), maxInd);
    
    bestYCtrData(thisBlockNo) = bestYData - bInf.height/2 + 1/2;
    bestXCtrData(thisBlockNo) = bestXData - bInf.width/2 + 1/2;
    blockHeights(thisBlockNo) = bInf.height;
    blockWidths(thisBlockNo)  = bInf.width;
    
    zIndToFit   = max(min(params.whichSlices), bestZData(thisBlockNo)-ceil(params.inferZWindow/2)) : ...
        min(max(params.whichSlices), bestZData(thisBlockNo)+ceil(params.inferZWindow/2));
    
    fitZ = polyfit(double(zIndToFit), double(maxCorrByZData(zIndToFit)'), params.zFitPower);
    
    maxCorrByZFit = polyval(fitZ, zIndToFit);
    bestZFit(thisBlockNo) = zIndToFit(maxCorrByZFit == max(maxCorrByZFit));
    
    % save a report of the peak correlations and fits that will be used to get neighborhoods
    if ~isempty(params.zFitFigName)
        [blocki, blockj] = ind2sub(params.mByNBlocks, thisBlockNo);
        
        ax1 = zFitPlotMat(blocki, blockj); hold(ax1, 'on');
        set(ax1,'box','off','ylim',[-.25 1], 'YTick',[round(max(maxCorrByZData),2)],...
            'xlim',[1 stackDim.depth], 'XTick', bestZData(thisBlockNo) , 'fontsize',6);
        
        % plot fit to data
        plot(ax1,[bestZFit(thisBlockNo) bestZFit(thisBlockNo)],[0 1], '-.', ...
            zIndToFit, maxCorrByZFit, '-', 'color', [.9 .5 .7],'linewidth',1);
        % plot data points with mark best z
        plot(ax1,repmat(bestZData(thisBlockNo),1,2),[0 1], '--','color', [.3 .5 .7],'linewidth',1);
        plot(ax1, 1:stackDim.depth, maxCorrByZData, '.', 'color', [.2 .4 .6], 'markersize',1.75)%;,...,
        %'markeredgecolor','k','linewidth',.05,'markersize',3);
        
        if blockj == 1 & blocki == ceil(params.mByNBlocks(1)/2), ylabel(ax1,'correlation');
        end
        if blockj == ceil(params.mByNBlocks(2)/2) & blocki == params.mByNBlocks(1), xlabel(ax1,'stack slice #')
        end
    end
    
    clear frameCorrVolNoRot;
end

if ~isempty(params.zFitFigName), saveas(zFitFig, fullfile(params.frameCorrDir, params.zFitFigName)); end

% fit x, y, z to get search range from correlations obtained so far
if params.zSearchRangeUseFit
    zIn = bestZFit;
else
    zIn = bestZData;
end


[xyzSearchRange, outliersXY] = fitXYZRSearchRange(bestXCtrData,bestYCtrData,...
    zIn,[], params);

% ------------ get initial rotation angle estimate for each block --------------- %
fprintf('getting initial searchRange on r for all blocks...\n');
highestCorr=-Inf;lowestCorr=Inf;
for bb = 1:length(params.whichBlocks)
    % select the relevant block location matrix and get its dimensions so
    % we can determine how many values will be in the correlation matrix
    thisBlockNo  = params.whichBlocks(bb);
    thisBlockLoc = blockLocations(:,:,thisBlockNo);
    bInf         = getBlockInf(thisBlockLoc);
    block        = movieFrame(bInf.indY,bInf.indX);
    
    fprintf('computing normxcorr2 for block %03i r estimate...\n',thisBlockNo);
    tic
    
    % use the block z searchRange that we just computed above
    bestStackSliceNoRot = stack(:,:,xyzSearchRange(3,thisBlockNo));
    % set up x and y ctr
    nbrhdInf.xCtr = xyzSearchRange(1,thisBlockNo);
    nbrhdInf.yCtr = xyzSearchRange(2,thisBlockNo);
    
    % preallocate matrix for rotation angles
    frameCorrVolRot = zeros(bInf.height+stackDim.height-1,bInf.width+stackDim.width-1,...
        length(params.coarseRotAngles), 'double');
    
    % get correlations for a pre-determined set of angles
    for rr = 1:length(params.coarseRotAngles)
        rotAngle = params.coarseRotAngles(rr);
        
        blockRot = rotateAndSelectBlock(movieFrame, bInf, rotAngle);
        frameCorrVolRot(:,:,rr) = computeBlockImageCorrs(blockRot, ...
            bestStackSliceNoRot, nbrhdInf, 'double');
        
    end
    toc
    
    % find peak correlation for rotations using same process as for z
    [~, frameCorrVolMaxIx] = max(frameCorrVolRot(:));
    [bestYDataRot, bestXDataRot, bestRIndData] =  ind2sub(size(frameCorrVolRot), frameCorrVolMaxIx);
    bestXCtrDataRot(thisBlockNo) = bestXDataRot - bInf.width/2 + 1/2;
    bestYCtrDataRot(thisBlockNo) = bestYDataRot - bInf.height/2 + 1/2;
    % figure out what angle corresponds to the best r index
    bestRData(thisBlockNo) = params.coarseRotAngles(bestRIndData);
    maxCorrByRData = squeeze(max(max(frameCorrVolRot,[],1),[],2));
    
    fitRot =  polyfit((params.coarseRotAngles).',maxCorrByRData, params.rFitPower);
    maxCorrByRFit = polyval(fitRot,params.rotAngleFromInd);
    
    [~, bestRIndFit] = max(maxCorrByRFit);
    bestRFit(thisBlockNo) = params.rotAngleFromInd(bestRIndFit);
    
    % keep track of best and worst correlations in order to set axis limits
    % later
    if highestCorr < max(maxCorrByRData), highestCorr = max(maxCorrByRData); end
    if lowestCorr > min(maxCorrByRData), lowestCorr   = min(maxCorrByRData); end
    
    % save a report of the peak correlations and fits that will be used to get neighborhoods
    if ~isempty(params.rFitFigName)
        [blocki, blockj] = ind2sub(params.mByNBlocks, thisBlockNo);
        ax1 = rFitPlotMat(blocki, blockj);
        hold(ax1, 'on');
        set(ax1,'box','off','ylim',[lowestCorr highestCorr], 'YTick',[round(max(maxCorrByRData),2)],...%'YTickLabel',[max(maxCorrByRData)], ...
            'xlim',[params.coarseRotAngles(1) params.coarseRotAngles(end)], 'XTick',[bestRData(thisBlockNo)],...
            'fontsize', 6);
        
        % plot fits
        plot(ax1,repmat(bestRFit(thisBlockNo),1,2),[0 1], '-.' ...
            ,params.rotAngleFromInd, maxCorrByRFit, '-', 'color', [.9 .5 .7], 'linewidth',1);
        % plot data
        plot(ax1,repmat(bestRData(thisBlockNo),1,2),[0 1], '--', 'color', [.3 .5 .7],'linewidth',1)
        plot(ax1, params.coarseRotAngles, maxCorrByRData, '.', 'color', [.2 .4 .6],'markersize',1.75);
        
        if blockj == 1 & blocki == ceil(params.mByNBlocks(1)/2), ylabel(ax1,'correlation');
        end
        if blockj == ceil(params.mByNBlocks(2)/2) & blocki == params.mByNBlocks(1), xlabel(ax1,'rotation angle (deg)')
        end
    end
    
    clear frameCorrVolRot;
    
end

if ~isempty(params.rFitFigName), saveas(rFitFig, fullfile(params.frameCorrDir, params.rFitFigName)); end



% fit x, y, z, r to get search range from correlations obtained looking at
% rotation
if params.rSearchRangeUseFit
    rIn = bestRFit;
else
    rIn = bestRData;
end
[xyzrSearchRange, outliersXY] = fitXYZRSearchRange(bestXCtrDataRot,bestYCtrDataRot,...
    xyzSearchRange(3,:),rIn,params,true);

if ~isempty(params.summarySaveName)
    % write to the summary.mat file
    sfile.xyzrSearchRange             = xyzrSearchRange;
    sfile.xyzrSearchRangeOutliersXY   = outliersXY;
end

end






