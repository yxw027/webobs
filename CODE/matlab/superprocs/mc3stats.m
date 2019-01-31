function DOUT=mc3stats(varargin)
%MC3STATS WebObs SuperPROC: Updates graphs/exports of MainCourante statistics.
%
%       MC3STATS(PROC) makes default outputs of PROC.
%
%       MC3STATS(PROC,TSCALE) updates all or a selection of TIMESCALES graphs:
%           TSCALE = '%' : all timescales defined by PROC.conf (default)
%	    TSCALE = '01y' or '30d,10y,'all' : only specified timescales
%	    (keywords must be in TIMESCALELIST of PROC.conf)
%
%	MC3STATS(PROC,[],REQDIR) makes graphs/exports for specific request directory REQDIR.
%	REQDIR must contain a REQUEST.rc file with dedicated parameters.
%
%       D = MCSTATS(PROC,...) returns a structure D containing all the PROC data:
%           D(i).id = node ID
%           D(i).t = time vector (for node i)
%           D(i).d = matrix of processed data (NaN = invalid data)
%
%       MC3STATS will use PROC's parameters from .conf file. Particularily, it
%       uses RAWFORMAT
%
%       MC3STATS can generate type of graphs which can be set with 'SUMMARYLIST|' parameter.
%       Available options are :
%           GUTENBERG-RICHTER   : Gutenberg/Richter law
%           GUTRICHTER_TIME     : Gutenberg/Richter law parameters over time
%           SWARM               : swarm detection on seismic rate
%           OMORI
%
%       Other specific paramaters are:
%           MC_EVENTTYPES_LIST|
%           EVENTTYPE_EXCLUDED_LIST|
%           EVENTSTATUS_EXCLUDED_LIST|
%           EVENTCOMMENT_EXCLUDED_REGEXP|
%           SEISMIC_RATE|
%           SEISMIC_RATE_NUM_EVENTS|50
%           SEISMIC_RATE_SAMPLING_INTERVAL|10m
%           SWARM_DETECTOR_LTA|60d
%           SWARM_DETECTOR_THRESH|2.5
%           SWARM_MIN_DURATION|12h
%
%
%	Authors: J.-M. Saurel / WEBOBS, IPGP
%	Created: 2019-01-31
%	Updated:

WO = readcfg;
wofun = sprintf('WEBOBS{%s}',mfilename);

% --- checks input arguments
if nargin < 1
	error('%s: must define PROC name.',wofun);
end

procmsg = sprintf(' %s',mfilename,varargin{:});
timelog(procmsg,1);


% gets PROC's configuration, associated nodes for any TSCALE and/or REQDIR and the data
[P,N,D] = readproc(WO,varargin{:});

% concatenates all nodes data
t = cat(1,D.t);
d = cat(1,D.d);
c = cat(1,D.c);
e = cat(1,D.e);
CLB = D(1).CLB;

% sort events by ascending time
[t,k] = sort(t);
d = d(k,:);
c = c(k,:);
e = e(k,:);

% at this stage, only one Node
n = 1;

% ====================================================================================================
% --- Seismic rate calculation, swarm detection and statistics
n_evts = field2num(P,'SEISMIC_RATE_NUM_EVENTS',50);
rate_type = field2str(P,'SEISMIC_RATE','classic'); 

rt = nan(1+length(t)-n_evts,1);
t_rt = nan(1+length(t)-n_evts,1);

switch rate_type
    % Calculate classic events/day seismic rate
    case 'classic'
        for k = n_evts:length(t)
          rt(1+k-n_evts) = n_evts/(t(k)-t(1+k-n_evts));
          t_rt(1+k-n_evts) = mean(t(1+k-n_evts:k));
        end
    % Calculate aki formulae seismic rate
    case 'aki'
        for k = n_evts:length(t)
          rt(1+k-n_evts) = n_evts/(2*sqrt(t(k)-t(1+k-n_evts)));
          t_rt(1+k-n_evts) = mean(t(1+k-n_evts:k));
        end
end


% --- Seismic rate interpolation
if isfield(P,'SEISMIC_RATE_SAMPLING_INTERVAL')
    SR.TIMESCALELIST = P.SEISMIC_RATE_SAMPLING_INTERVAL;
    SR.NOW = now;
    SR = timescales(SR);
    samp_int = SR.DATELIST{1}(2) - SR.DATELIST{1}(1); 
    clear SR;
else
    samp_int = 10/1440;
end

t_rate = floor(min(min(P.DATELIST{:}))):samp_int:ceil(P.NOW);
rate = interp1(t_rt,rt,t_rate);
k = find(~isnan(rate));
rate(isnan(rate)) = rate(k(1));


% --- LTA/STA swarm detector on seismic rate
if isfield(P,'SWARM_DETECTOR_LTA')
    SW.TIMESCALELIST = P.SWARM_DETECTOR_LTA;
    SW.NOW = now;
    SW = timescales(SW);
    detect_LTA = SW.DATELIST{1}(2) - SW.DATELIST{1}(1); 
    clear SW;
else
    detect_LTA = 60;
end

if isfield(P,'SWARM_MIN_DURATION')
    SW.TIMESCALELIST = P.SWARM_MIN_DURATION;
    SW.NOW = now;
    SW = timescales(SW);
    swarm_min_dur = SW.DATELIST{1}(2) - SW.DATELIST{1}(1); 
    clear SW;
else
    swarm_min_dur = 12/24;
end

% LtaFilt initialization
C4 = 1-exp(-2*pi*samp_int/detect_LTA);
% EventThresh
thresh = field2num(P,'SWARM_DETECTOR_THRESH',2.5);

rate_lta = zeros(1,length(rate));
% If first rate data is already a swarm value, initialize lta to a low value
if rate(1) > 20
    rate_lta(1) = 20/tresh;
else
    rate_lta(1) = rate(1);
end
rate_lta_stale = rate_lta(1);

Warning = nan(1,length(rate));
swarms_datelim = [];

for k = 2:length(rate)
    % Update lta only if a detection is not ongoing, else keep frozen lta
    if isnan(Warning(k-1))
        rate_lta(k) = rate_lta(k-1)+C4*(rate(k)-rate_lta(k-1));
    else
        rate_lta(k) = rate_lta_stale;
    end
    % Check if threshold reached, if yes, freeze lta value
    if (rate(k)>thresh.*rate_lta(k))
        Warning(k) = 1;
        rate_lta_stale = rate_lta(k);
    end
    % If a new detection just started, store the start timestamp
    if isnan(Warning(k-1)) && ~isnan(Warning(k))
        swarm_start = t_rate(k);
    end
    % If an ongoing detection ends and last more than the minimum duration, update swarm list
    if ~isnan(Warning(k-1)) && isnan(Warning(k)) && (t_rate(k)-swarm_start > swarm_min_dur)
        swarms_datelim = [swarms_datelim;swarm_start t_rate(k)];
    end
end
% If still in detection at the end, close the ongoing detection now
if ~isnan(Warning(end))
    swarms_datelim = [swarms_datelim;swarm_start t_rate(end)];
end


% --- Moment and NRJ calculation for each event
moment_MC = nan(length(t),1);
energy_MC = nan(length(t),1);
moment_catalog = nan(length(t),1);
energy_catalog = nan(length(t),1);

% Finds events that have a MC magnitude and no catalog magnitude, take MC magnitude
k = find(~isnan(d(:,4)) & isnan(d(:,8)));
moment_MC(k) = seismic_moment(d(k,4),'feuillard80');
energy_MC(k) = seismic_energy(d(k,4),'feuillard80');

% Finds events that have a MC magnitude and a catalog magnitude, take catalog magnitude
k = find(~isnan(d(:,4)) & ~isnan(d(:,8)));
moment_MC(k) = seismic_moment(d(k,8),'feuillard80');
energy_MC(k) = seismic_energy(d(k,8),'feuillard80');

% Finds events that have a catalog magnitude
k = find(~isnan(d(:,8)));
moment_catalog(k) = seismic_moment(d(k,8),'kanamori');
energy_catalog(k) = seismic_energy(d(k,8),'kanamori');


% --- Swarm statistics
% If swarms were found, update the statistics table
if find(swarms_datelim)
    n_swarms = size(swarms_datelim);
    % Init all 7 statistics :   number of events in swarm
    %                           inter-swarm time
    %                           swarm moment from MC
    %                           swarm energy from MC
    %                           swarm moment from catalog
    %                           swarm energy from catalog
    %                           percentage of events in the catalog
    swarms_statistics = nan(length(n_swarms(1)),6);
    swarms_x = nan(length(n_swarms(1)),4);
    swarms_y = nan(length(n_swarms(1)),4);
    % Inter-swarm time
    swarms_statistics(2:n_swarms,2) = [swarms_datelim(2:end,1)-swarms_datelim(1:end-1,2)];
    for i = 1:n_swarms(1)
        % Finds events between start and end of the swarm
        k = find(t_rt>=swarms_datelim(i,1) & t_rt<=swarms_datelim(i,2));
        if ~isempty(k)
            swarms_statistics(i,1) = length(k);
            swarms_statistics(i,3) = sum(moment_MC(~isnan(moment_MC(k))));
            swarms_statistics(i,4) = sum(energy_MC(~isnan(energy_MC(k))));
            swarms_statistics(i,5) = sum(moment_catalog(~isnan(moment_catalog(k))));
            swarms_statistics(i,6) = sum(energy_catalog(~isnan(energy_catalog(k))));
        end
        % Finds events between start and end of swarm and in the catalog (with a catalog magnitude)
        k = find(~isnan(d(k,8)));
        if swarms_statistics(i,1) > 0
            swarms_statistics(i,7) = 100*length(k)/swarms_statistics(i,1);
        end
        % Create swarm boxes for plot
        swarms_x(i,:) = [swarms_datelim(i,1);swarms_datelim(i,2);swarms_datelim(i,2);swarms_datelim(i,1)];
        swarms_y(i,:) = [min(rt);min(rt);max(rt);max(rt)];  
    end
end


% ====================================================================================================
% Make the graphs

for r = 1:length(P.GTABLE)

    summary='SWARM';
    if any(strcmp(P.SUMMARYLIST,summary))
    	figure, clf, orient tall
    	
    	h = subplot(2,1,1); extaxes
        fill(swarms_x,swarms_y,'r')
        hold on
        plot(t_rate,rate,'k')
        plot(t_rate,rate_lta.*thresh,'b')
        hold off
        set(gca,'YScale','log')
        datetick('x','dd/mm/yy');
        ylabel('evts/day');
        title('Instant seismicity rate')

        subplot(2,1,2); extaxes
        k = find(~isnan(energy_MC));
        semilogy(t(k),cumsum(energy_MC(k)),'r');
        hold on
        semilogy(t(k),cumsum(energy_catalog(k)),'k')
        hold off
        datetick('x','dd/mm/yy');
        xlabel('date');
        ylabel('Cumulated energy (MJ)');
        legend('MainCourante','catalog');
        legend('boxoff');
        legend('location','southeast');
		mkgraph(WO,sprintf('%s_%s',lower(N(n).ID),P.GTABLE(r).TIMESCALE),P.GTABLE(r))
    end

%    summary='GUTENBERG-RICHTER';
%    if any(strcmp(P.SUMMARYLIST,summary))
%    end

%    summary='GUTRICHTER_TIME';
%    if any(strcmp(P.SUMMARYLIST,summary))
%    end

%    summary='OMORI';
%    if any(strcmp(P.SUMMARYLIST,summary))
%    end
end

if P.REQUEST
	mkendreq(WO,P);
end

timelog(procmsg,2)


% Returns data in DOUT
if nargout > 0
	DOUT = D;
end

