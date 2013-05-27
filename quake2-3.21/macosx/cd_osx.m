//------------------------------------------------------------------------------------------------------------------------------------------------------------
//
// "cd_osx.m" - MacOS X audio CD driver.
//
// Written by:	awe			               	[mailto:awe@fruitz-of-dojo.de].
//	            ©2001-2006 Fruitz Of Dojo 	[http://www.fruitz-of-dojo.de].
//
// Quake IIª is copyrighted by id software	[http://www.idsoftware.com].
//
// Version History:
// v1.0.8: Rewritten. Uses now QuickTime for playback. Added support for MP3 and MP4 [AAC] playback.
// v1.0.3: Fixed an issue with requesting a track number greater than the max number.
// v1.0.1: Added "cdda" as extension for detection of audio-tracks [required by MacOS X v10.1 or later]
// v1.0.0: Initial release.
//
//------------------------------------------------------------------------------------------------------------------------------------------------------------

#pragma mark Includes

#import <Cocoa/Cocoa.h>
#import <CoreAudio/AudioHardware.h>
#import <QTKit/QTKit.h>
#import <sys/mount.h>
#import <pthread.h>

#import "client.h"
#import "cd_osx.h"
#import "sys_osx.h"
#import "Quake2.h"

#pragma mark -

//------------------------------------------------------------------------------------------------------------------------------------------------------------

#pragma mark Variables

cvar_t *					cd_volume;

/*
 static UInt16				gCDTrackCount;
 static UInt16				gCurCDTrack;
 static NSMutableArray *		gCDTrackList;
 static char					gCDDevice[MAX_OSPATH];
 static BOOL					gCDLoop;
 static BOOL					gCDNextTrack;
 static Movie				gCDController = NULL;
 */

#pragma mark -

//------------------------------------------------------------------------------------------------------------------------------------------------------------

#pragma mark Function Prototypes

BOOL				CDAudio_GetTrackList (void);
void				CDAudio_Enable (BOOL theState);

static	void		CDAudio_Error (cderror_t theErrorNumber);
static	SInt32		CDAudio_StripVideoTracks (Movie theMovie);
static	void		CDAudio_AddTracks2List (NSString *theMountPath, NSArray *theExtensions);
static 	void 		CD_f (void);

static QTMovie* currentTrack;
static NSMutableArray* trackList;
static NSMutableDictionary* trackData;
static BOOL loop;
static UInt16 trackNumber;

#pragma mark -

//------------------------------------------------------------------------------------------------------------------------------------------------------------

void	CDAudio_Error (cderror_t theErrorNumber)
{
    if ([[NSApp delegate] mediaFolder] == NULL)
    {
        Con_Print ("Audio-CD driver: ");
    }
    else
    {
        Con_Print ("MP3/MP4 driver: ");
    }
    
    switch (theErrorNumber)
    {
        case CDERR_ALLOC_TRACK:
            Con_Print ("Failed to allocate track!\n");
            break;
        case CDERR_MOVIE_DATA:
            Con_Print ("Failed to retrieve track data!\n");
            break;
        case CDERR_AUDIO_DATA:
            Con_Print ("File without audio track!\n");
            break;
        case CDERR_QUICKTIME_ERROR:
            Con_Print ("QuickTime error!\n");
            break;
        case CDERR_THREAD_ERROR:
            Con_Print ("Failed to initialize thread!\n");
            break;
        case CDERR_NO_MEDIA_FOUND:
            Con_Print ("No Audio-CD found.\n");
            break;
        case CDERR_MEDIA_TRACK:
            Con_Print ("Failed to retrieve media track!\n");
            break;
        case CDERR_MEDIA_TRACK_CONTROLLER:
            Con_Print ("Failed to retrieve track controller!\n");
            break;
        case CDERR_EJECT:
            Con_Print ("Can\'t eject Audio-CD!\n");
            break;
        case CDERR_NO_FILES_FOUND:
            if ([[NSApp delegate] mediaFolder] == NULL)
            {
                Con_Print ("No audio tracks found.\n");
            }
            else
            {
                Con_Print ("No files found with the extension \'.mp3\', \'.mp4\' or \'.m4a\'!\n");
            }
            break;
    }
}

//------------------------------------------------------------------------------------------------------------------------------------------------------------

SInt32	CDAudio_StripVideoTracks (Movie theMovie)
{
	SInt64	i = GetMovieTrackCount (theMovie);
    
    for (; i >= 1; i--)
    {
        Track		myCurTrack = GetMovieIndTrack (theMovie, i);
        OSType 	myMediaType;
        
        GetMediaHandlerDescription (GetTrackMedia (myCurTrack), &myMediaType, NULL, NULL);
		
        if (myMediaType != SoundMediaType && myMediaType != MusicMediaType)
        {
            DisposeMovieTrack (myCurTrack);
        }
    }
    
    return (GetMovieTrackCount (theMovie));
}

//------------------------------------------------------------------------------------------------------------------------------------------------------------

void	CDAudio_AddTracks2List (NSString *theMountPath, NSArray *theExtensions)
{
    NSFileManager		*myFileManager = [NSFileManager defaultManager];
    
    NSDirectoryEnumerator	*myDirEnum = [myFileManager enumeratorAtPath: theMountPath];
    
    if (myDirEnum != NULL)
    {
        for (NSString* myFilePath in myDirEnum) {
            if ([[NSApp delegate] abortMediaScan] == YES) {
                break;
            }
            
            for (NSString* myExtension in theExtensions) {
                if ([[myFilePath pathExtension] isEqualToString: myExtension]) {
                    [trackList addObject:[theMountPath stringByAppendingPathComponent: myFilePath]];
                }
            }
        }
    }
}

//------------------------------------------------------------------------------------------------------------------------------------------------------------

BOOL	CDAudio_GetTrackList (void)
{
    NSAutoreleasePool 		*myPool;
    
    // release previously allocated memory:
    CDAudio_Shutdown ();
    
    // get memory for the new tracklisting:
    trackList = [[NSMutableArray alloc] init];
    myPool = [[NSAutoreleasePool alloc] init];
    trackData = [[NSMutableDictionary alloc] init];
    
    // Get the current MP3 listing or retrieve the TOC of the AudioCD:
    if ([[NSApp delegate] mediaFolder] != NULL)
    {
        NSString	*myMediaFolder = [[NSApp delegate] mediaFolder];
        Con_Print ("Scanning for audio tracks. Be patient!\n");
        CDAudio_AddTracks2List (myMediaFolder, [NSArray arrayWithObjects: @"mp3", @"mp4", @"m4a", NULL]);
    }
    
    // release the pool:
    [myPool release];
    
    // just security:
    if (![trackList count])
    {
        [trackList release];
        trackList = NULL;
        CDAudio_Error (CDERR_NO_FILES_FOUND);
        return (0);
    }
    return (1);
}

//------------------------------------------------------------------------------------------------------------------------------------------------------------

void	CDAudio_Play (int theTrack, qboolean theLoop)
{
    if (trackList != NULL && [trackList count] != 0)
    {
        //NSMovie* myMovie;
        NSError* error;
        
        // check for mismatching CD track number:
        if (theTrack > [trackList count] || theTrack <= 0)
        {
            theTrack = 1;
        }
        
        if (currentTrack != NULL)
        {
            CDAudio_Stop();
        }
        
        if (NULL == (currentTrack = [trackData valueForKey:[trackList objectAtIndex: theTrack - 1]])) {
            currentTrack = [QTMovie movieWithFile:[trackList objectAtIndex: theTrack - 1]
                                            error:&error];
            [trackData setValue:currentTrack forKey:[trackList objectAtIndex:theTrack - 1]];
        }
        
        if (currentTrack != NULL)
        {
            trackNumber	= theTrack;
            loop		= theLoop;
            [currentTrack gotoBeginning];
            [currentTrack play];
        }
        else
        {
            CDAudio_Error (CDERR_MEDIA_TRACK_CONTROLLER);
        }
    }
}

//------------------------------------------------------------------------------------------------------------------------------------------------------------

void	CDAudio_Stop (void)
{
    if (currentTrack != NULL)
    {
        [currentTrack stop];
        currentTrack = NULL;
    }
}

//------------------------------------------------------------------------------------------------------------------------------------------------------------

void	CDAudio_Pause (void)
{
    if (currentTrack) {
        [currentTrack stop];
    }
}

//------------------------------------------------------------------------------------------------------------------------------------------------------------

void	CDAudio_Resume (void)
{
    if (currentTrack) {
        [currentTrack play];
    }
}

//------------------------------------------------------------------------------------------------------------------------------------------------------------

void	CDAudio_Update (void)
{
    // update volume settings:
    /*
     if (gCDController != NULL)
     {
     SetMovieVolume (gCDController, kFullVolume * cd_volume->value);
     
     if (GetMovieActive (gCDController) == YES)
     {
     if (IsMovieDone (gCDController) == NO)
     {
     MoviesTask (gCDController, 0);
     }
     else
     {
     if (gCDLoop == YES)
     {
     GoToBeginningOfMovie (gCDController);
     StartMovie (gCDController);
     }
     else
     {
     gCurCDTrack++;
     CDAudio_Play (gCurCDTrack, NO);
     }
     }
     }
     }
     */
}

//------------------------------------------------------------------------------------------------------------------------------------------------------------

void	CDAudio_Enable (BOOL theState)
{
    static BOOL	myCDIsEnabled = YES;
    
    if (myCDIsEnabled != theState)
    {
        static BOOL	myCDWasPlaying = NO;
        
        if (theState == NO)
        {
            if (currentTrack != NULL)
            {
                CDAudio_Pause ();
                myCDWasPlaying = YES;
            }
            else
            {
                myCDWasPlaying = NO;
            }
        }
        else
        {
            if (myCDWasPlaying == YES)
            {
                CDAudio_Resume ();
            }
        }
        
        myCDIsEnabled = theState;
    }
}

//------------------------------------------------------------------------------------------------------------------------------------------------------------

int	CDAudio_Init (void)
{
    // register the volume var:
    cd_volume = Cvar_Get ("cd_volume", "1", CVAR_ARCHIVE);
    
    // add "cd" and "mp3" console command:
    if ([[NSApp delegate] mediaFolder] != NULL)
    {
        Cmd_AddCommand ("mp3", CD_f);
        Cmd_AddCommand ("mp4", CD_f);
    }
    
    trackNumber = 0;
    
    if (trackList != NULL)
    {
        if ([[NSApp delegate] mediaFolder] == NULL)
        {
            Con_Print ("QuickTime CD driver initialized...\n");
        }
        else
        {
            Con_Print ("QuickTime MP3/MP4 driver initialized...\n");
        }
        
        return (1);
    }
    
    Con_Print ("QuickTime MP3/MP4 driver failed.\n");
    return (0);
}

//------------------------------------------------------------------------------------------------------------------------------------------------------------

void	CDAudio_Shutdown (void)
{
    // shutdown the audio IO:
    CDAudio_Stop ();
    
    if (trackList) {
        [trackList release];
    }
    
    if (trackData) {
        [trackData release];
    }
}

//------------------------------------------------------------------------------------------------------------------------------------------------------------

void CD_On(void) {
    if (trackList == NULL) {
        CDAudio_GetTrackList();
    }
    CDAudio_Play(1, 0);
}

void CD_Reset(void) {
    CDAudio_Stop ();
    if (CDAudio_GetTrackList ())
    {
        Com_Printf ("MP3/MP4 files found. %d tracks (\"%s\").\n", [trackList count]);
    }
    else
    {
        CDAudio_Error (CDERR_NO_FILES_FOUND);
    }
    
}

void CD_Info(void) {
    if ([trackList count] == 0)
    {
        CDAudio_Error (CDERR_NO_FILES_FOUND);
    }
    else
    {
        if (currentTrack != NULL)
        {
            Com_Printf ("Playing track %d of %d: %s.\n",
                        trackNumber, [trackList count],
                        [[trackList objectAtIndex:trackNumber-1] UTF8String]);
        }
        else
        {
            Com_Printf ("Not playing. Tracks: %d.\n", [trackList count]);
        }
        Com_Printf ("Volume is: %.2f.\n", cd_volume->value);
    }
}

void	CD_f (void)
{
    char	*myCommandOption;
    
    // this command requires options!
    if (Cmd_Argc () < 2)
    {
        return;
    }
    
    // get the option:
    myCommandOption = Cmd_Argv (1);
    
    // turn CD playback on:
    if (Q_strcasecmp (myCommandOption, "on") == 0)
    {
        CD_On();
		return;
    }
    
    // turn CD playback off:
    if (Q_strcasecmp (myCommandOption, "off") == 0)
    {
        CDAudio_Shutdown ();
        
		return;
    }
    
    // just for compatibility:
    if (Q_strcasecmp (myCommandOption, "remap") == 0)
    {
        return;
    }
    
    // reset the current CD:
    if (Q_strcasecmp (myCommandOption, "reset") == 0)
    {
        CD_Reset();
        
        return;
    }
    
    // the following commands require a valid track array, so build it, if not present:
    if ([trackList count] == 0)
    {
        CDAudio_GetTrackList ();
        if ([trackList count] == 0)
        {
            CDAudio_Error (CDERR_NO_FILES_FOUND);
            return;
        }
    }
    
    // play the selected track:
    if (Q_strcasecmp (myCommandOption, "play") == 0)
    {
        CDAudio_Play (atoi (Cmd_Argv (2)), 0);
        
		return;
    }
    
    // loop the selected track:
    if (Q_strcasecmp (myCommandOption, "loop") == 0)
    {
        CDAudio_Play (atoi (Cmd_Argv (2)), 1);
        
		return;
    }
    
    // stop the current track:
    if (Q_strcasecmp (myCommandOption, "stop") == 0)
    {
        CDAudio_Stop ();
        
		return;
    }
    
    // pause the current track:
    if (Q_strcasecmp (myCommandOption, "pause") == 0)
    {
        CDAudio_Pause ();
        
		return;
    }
    
    // resume the current track:
    if (Q_strcasecmp (myCommandOption, "resume") == 0)
    {
        CDAudio_Resume ();
        
		return;
    }
    
    // output CD info:
    if (Q_strcasecmp(myCommandOption, "info") == 0)
    {
        CD_Info();
        
		return;
	}
}

//______________________________________________________________________________________________________________eOF
