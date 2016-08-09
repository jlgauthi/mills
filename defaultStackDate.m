function refDate = defaultStackDate(subj)
refDateSt = struct( 'J114','2015-11-30',...
                    'J115', '2015-09-25',...
                    'J116', '2015-10-02',...
                    'J117', '2015-09-25',...
                    'J118', '2015-10-01',...
                    'J122', '2015-09-27',...
                    'J123', '2015-09-25');
try
    refDate = refDateSt.(subj);
catch
    error('subject does not have listed reference date');
end
end
