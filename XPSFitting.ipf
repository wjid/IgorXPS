#pragma TextEncoding = "UTF-8"
#pragma rtGlobals=3
#pragma version=1.0
#pragma ModuleName = XPSFit

// ═══════════════════════════════════════════════════════════════════════════════
//  XPSFitting — General-Purpose XPS Peak Fitting Package for Igor Pro 9
// ═══════════════════════════════════════════════════════════════════════════════
//
//  Author:   Will DeBenedetti
//  Version:  1.0  (May 2026)
//  License:  GPLV2
//
//  Data folder layout:
//    root:XPSFit:
//      Globals/       — package-wide globals
//      Data/          — raw spectra: BE_<name>, Int_<name>
//      Backgrounds/   — computed backgrounds: BG_<name>
//      Peaks/         — peak parameter + curve waves
//      Fits/          — envelope waves
//      Results/       — output tables
//
// ═══════════════════════════════════════════════════════════════════════════════


// ─────────────────────────────────────────────────────────────────────────────
//  SECTION 1 — Constants
// ─────────────────────────────────────────────────────────────────────────────

static Constant kPanelWidth   = 420
static Constant kPanelHeight  = 700
static Constant kGraphWidth   = 600
static Constant kGraphHeight  = 450
static Constant kMaxPeaks     = 20
static Constant kShirleyIter  = 50
static Constant kPI           = 3.141592653589793
static Constant kLN2          = 0.6931471805599453
static Constant kSQRT2LN2    = 1.1774100225
static Constant kFWHM2SIGMA  = 0.42466090014


// ─────────────────────────────────────────────────────────────────────────────
//  SECTION 2 — Menu
// ─────────────────────────────────────────────────────────────────────────────

Menu "XPS Fitting"
	"Open XPS Fitting Panel", /Q, XPSFit#XPS_OpenPanel()
	"-"
	Submenu "Data"
		"Load VAMAS File (.vms)...", /Q, XPSFit#XPS_LoadVAMASDialog()
		"Load Igor Binary (.ibw)...", /Q, XPSFit#XPS_LoadIBWDialog()
		"Remove Current Spectrum", /Q, XPSFit#XPS_RemoveSpectrum()
	End
	Submenu "Background"
		"Compute Linear", /Q, XPSFit#XPS_ComputeBackground("Linear")
		"Compute Shirley", /Q, XPSFit#XPS_ComputeBackground("Shirley")
		"Compute Tougaard", /Q, XPSFit#XPS_ComputeBackground("Tougaard")
		"Clear Background", /Q, XPSFit#XPS_ClearBackground()
	End
	Submenu "Peaks"
		"Add Peak at Cursor", /Q, XPSFit#XPS_AddPeakAtCursor()
		"Remove Last Peak", /Q, XPSFit#XPS_RemoveLastPeak()
		"Clear All Peaks", /Q, XPSFit#XPS_ClearAllPeaks()
	End
	"Fit Peaks", /Q, XPSFit#XPS_RunFit()
	"-"
	"About XPS Fitting...", /Q, XPSFit#XPS_About()
End


// ─────────────────────────────────────────────────────────────────────────────
//  SECTION 3 — Initialization
// ─────────────────────────────────────────────────────────────────────────────

static Function XPS_Init()
	String savDF = GetDataFolder(1)

	NewDataFolder/O root:XPSFit
	NewDataFolder/O root:XPSFit:Globals
	NewDataFolder/O root:XPSFit:Data
	NewDataFolder/O root:XPSFit:Backgrounds
	NewDataFolder/O root:XPSFit:Peaks
	NewDataFolder/O root:XPSFit:Fits
	NewDataFolder/O root:XPSFit:Results

	SetDataFolder root:XPSFit:Globals

	String/G gCurrentSpectrum = ""
	String/G gSpectrumList = ""
	String/G gBGType = "Shirley"
	String/G gLineshape = "GL"
	Variable/G gNumPeaks = 0
	Variable/G gMixRatio = 0.3
	Variable/G gTabNum = 0
	Variable/G gShirleyIter = kShirleyIter
	Variable/G gTougaardB = 2866
	Variable/G gTougaardC = 1643
	Variable/G gShowResiduals = 1
	Variable/G gChargeCorr = 0
	Variable/G gActivePeak = 0

	SetDataFolder savDF
End

static Function XPS_EnsureInit()
	if (!DataFolderExists("root:XPSFit"))
		XPS_Init()
	endif
End


// ─────────────────────────────────────────────────────────────────────────────
//  SECTION 4 — Data I/O: VAMAS Parser (ISO 14976)
// ─────────────────────────────────────────────────────────────────────────────
//
//  VAMAS is a positional text format: each line's meaning is determined by
//  its sequential position in the file.  We support the common modes:
//    experiment mode = NORM, SDP
//    scan mode       = REGULAR
//
//  Ref: Dench, Hazell, Seah, Surf. Interface Anal. 13, 63 (1988).
//

static Function XPS_LoadVAMASDialog()
	XPS_EnsureInit()

	Variable refNum
	Open/D/R/F="VAMAS Files (*.vms):.vms;All Files:.*;" refNum
	String filePath = S_fileName
	if (strlen(filePath) == 0)
		return -1
	endif

	XPS_ParseVAMAS(filePath)
End

static Function XPS_ParseVAMAS(filePath)
	String filePath

	Variable refNum
	Open/R refNum as filePath
	if (refNum == 0)
		DoAlert 0, "Could not open file."
		return -1
	endif

	String savDF = GetDataFolder(1)
	String oneLine = ""
	Variable i

	// ── File header ──

	// Line 1: format identifier — must contain "VAMAS"
	FReadLine refNum, oneLine
	if (strsearch(XPS_Trim(oneLine), "VAMAS", 0) < 0)
		DoAlert 0, "This does not appear to be a VAMAS file."
		Close refNum
		return -1
	endif

	// Lines 2-5: institution, instrument, operator, experiment ID
	FReadLine refNum, oneLine
	FReadLine refNum, oneLine
	FReadLine refNum, oneLine
	FReadLine refNum, oneLine

	// Number of comment lines + skip them
	FReadLine refNum, oneLine
	Variable nComment = str2num(XPS_Trim(oneLine))
	for (i = 0; i < nComment; i += 1)
		FReadLine refNum, oneLine
	endfor

	// Experiment mode (NORM, SDP, MAP, MAPDP, etc.)
	FReadLine refNum, oneLine
	String expMode = XPS_Trim(oneLine)

	// Scan mode (REGULAR, IRREGULAR, MAPPING)
	FReadLine refNum, oneLine
	String scanMode = XPS_Trim(oneLine)

	// MAP/MAPDP header extras
	if (CmpStr(expMode, "MAP") == 0 || CmpStr(expMode, "MAPDP") == 0)
		FReadLine refNum, oneLine   // number of spectral regions
		Variable nSpecReg = str2num(XPS_Trim(oneLine))
		FReadLine refNum, oneLine   // number of analysis positions x
		FReadLine refNum, oneLine   // number of analysis positions y
		for (i = 0; i < nSpecReg; i += 1)
			FReadLine refNum, oneLine  // spectral region start
			FReadLine refNum, oneLine  // spectral region end
		endfor
	endif

	// Number of experimental variables
	FReadLine refNum, oneLine
	Variable nExpVar = str2num(XPS_Trim(oneLine))
	// Each has label + units (2 lines)
	for (i = 0; i < nExpVar; i += 1)
		FReadLine refNum, oneLine
		FReadLine refNum, oneLine
	endfor

	// Number of entries in inclusion/exclusion list
	FReadLine refNum, oneLine
	Variable nIncl = str2num(XPS_Trim(oneLine))
	for (i = 0; i < nIncl; i += 1)
		FReadLine refNum, oneLine
	endfor

	// Number of manually entered items
	FReadLine refNum, oneLine

	// Number of future upgrade experiment entries
	FReadLine refNum, oneLine
	Variable nFutureExp = str2num(XPS_Trim(oneLine))
	for (i = 0; i < nFutureExp; i += 1)
		FReadLine refNum, oneLine  // label
		FReadLine refNum, oneLine  // units
	endfor

	// Number of future upgrade block entries
	FReadLine refNum, oneLine
	Variable nFutureBlk = str2num(XPS_Trim(oneLine))

	// Number of blocks
	FReadLine refNum, oneLine
	Variable nBlocks = str2num(XPS_Trim(oneLine))

	Print "XPS Fitting: VAMAS file — " + num2str(nBlocks) + " block(s), mode=" + expMode

	// ── Parse each block ──
	Variable blk
	for (blk = 0; blk < nBlocks; blk += 1)
		XPS_ReadVAMASBlock(refNum, expMode, nFutureBlk)
	endfor

	Close refNum
	SetDataFolder savDF
	Print "XPS Fitting: VAMAS import complete."
End


// Read one VAMAS block (one spectrum) from an open file reference
static Function XPS_ReadVAMASBlock(refNum, expMode, nFutureBlk)
	Variable refNum
	String expMode
	Variable nFutureBlk

	String savDF = GetDataFolder(1)
	String oneLine = ""
	Variable i

	// Block ID and sample ID
	FReadLine refNum, oneLine
	String blockID = XPS_Trim(oneLine)
	FReadLine refNum, oneLine
	String sampleID = XPS_Trim(oneLine)

	// Date/time: year, month, day, hour, min, sec (6 lines)
	for (i = 0; i < 6; i += 1)
		FReadLine refNum, oneLine
	endfor

	// Hours in advance of GMT
	FReadLine refNum, oneLine

	// Block comment lines
	FReadLine refNum, oneLine
	Variable nBlkComment = str2num(XPS_Trim(oneLine))
	for (i = 0; i < nBlkComment; i += 1)
		FReadLine refNum, oneLine
	endfor

	// Technique (XPS, UPS, AES, etc.)
	FReadLine refNum, oneLine
	String technique = XPS_Trim(oneLine)

	// SDP/MAPDP extra: x coord, y coord, sputtering source energy,
	//   sputtering time (4 lines)
	if (CmpStr(expMode, "SDP") == 0 || CmpStr(expMode, "MAPDP") == 0)
		for (i = 0; i < 4; i += 1)
			FReadLine refNum, oneLine
		endfor
	endif

	// Analysis source label
	FReadLine refNum, oneLine
	String sourceLabel = XPS_Trim(oneLine)

	// Analysis source energy (eV)
	FReadLine refNum, oneLine
	Variable sourceEnergy = str2num(XPS_Trim(oneLine))

	// Source strength, beam width x, beam width y (3 lines)
	FReadLine refNum, oneLine
	FReadLine refNum, oneLine
	FReadLine refNum, oneLine

	// MAP/MAPDP: field of view x, y
	if (CmpStr(expMode, "MAP") == 0 || CmpStr(expMode, "MAPDP") == 0)
		FReadLine refNum, oneLine
		FReadLine refNum, oneLine
	endif

	// MAP/MAPDP/SEM: first/last linescan coords (4 lines)
	if (CmpStr(expMode, "MAP") == 0 || CmpStr(expMode, "MAPDP") == 0 || CmpStr(expMode, "SEM") == 0)
		for (i = 0; i < 4; i += 1)
			FReadLine refNum, oneLine
		endfor
	endif

	// Polar angle of incidence, azimuth (2 lines)
	FReadLine refNum, oneLine
	FReadLine refNum, oneLine

	// Analyser mode (FAT, FRR, CONST)
	FReadLine refNum, oneLine

	// Analyser pass energy or retard ratio
	FReadLine refNum, oneLine

	// AES only: differential width
	if (CmpStr(technique, "AES") == 0)
		FReadLine refNum, oneLine
	endif

	// Magnification, work function, target bias (3 lines)
	FReadLine refNum, oneLine
	FReadLine refNum, oneLine
	FReadLine refNum, oneLine

	// Analysis width x, y (2 lines)
	FReadLine refNum, oneLine
	FReadLine refNum, oneLine

	// Analyser take-off polar angle, azimuth (2 lines)
	FReadLine refNum, oneLine
	FReadLine refNum, oneLine

	// Species label (e.g. "C1s", "O1s", "U4f")
	FReadLine refNum, oneLine
	String speciesLabel = XPS_Trim(oneLine)

	// Transition/charge state label
	FReadLine refNum, oneLine

	// Charge of detected particle
	FReadLine refNum, oneLine

	// X label, X units
	FReadLine refNum, oneLine
	String xLabel = XPS_Trim(oneLine)
	FReadLine refNum, oneLine

	// X start, X step
	FReadLine refNum, oneLine
	Variable xStart = str2num(XPS_Trim(oneLine))
	FReadLine refNum, oneLine
	Variable xStep = str2num(XPS_Trim(oneLine))

	// Number of corresponding variables
	FReadLine refNum, oneLine
	Variable nCorVar = str2num(XPS_Trim(oneLine))
	// Label + units for each (2 lines each)
	for (i = 0; i < nCorVar; i += 1)
		FReadLine refNum, oneLine
		FReadLine refNum, oneLine
	endfor

	// Signal mode
	FReadLine refNum, oneLine

	// Dwell time
	FReadLine refNum, oneLine

	// Number of scans
	FReadLine refNum, oneLine
	Variable nScans = str2num(XPS_Trim(oneLine))

	// Signal time correction
	FReadLine refNum, oneLine

	// SDP/MAPDP: sputtering source, energy, current, width x/y,
	//   polar angle, azimuth (7 lines)
	if (CmpStr(expMode, "SDP") == 0 || CmpStr(expMode, "MAPDP") == 0)
		for (i = 0; i < 7; i += 1)
			FReadLine refNum, oneLine
		endfor
	endif

	// Sample normal: polar tilt, azimuth, rotation (3 lines)
	FReadLine refNum, oneLine
	FReadLine refNum, oneLine
	FReadLine refNum, oneLine

	// Additional numerical parameters
	FReadLine refNum, oneLine
	Variable nAddParams = str2num(XPS_Trim(oneLine))
	// Each has label + units + value (3 lines)
	for (i = 0; i < nAddParams; i += 1)
		FReadLine refNum, oneLine
		FReadLine refNum, oneLine
		FReadLine refNum, oneLine
	endfor

	// Future upgrade block entries (label + value, 2 lines each)
	for (i = 0; i < nFutureBlk; i += 1)
		FReadLine refNum, oneLine
		FReadLine refNum, oneLine
	endfor

	// Number of ordinate values
	FReadLine refNum, oneLine
	Variable nOrdValues = str2num(XPS_Trim(oneLine))

	// Min and max ordinate for each corresponding variable
	for (i = 0; i < nCorVar; i += 1)
		FReadLine refNum, oneLine   // min
		FReadLine refNum, oneLine   // max
	endfor

	// Number of data points
	Variable nDataPts = nOrdValues
	if (nCorVar > 0)
		nDataPts = nOrdValues / nCorVar
	endif

	// ── Create waves ──
	String specName = CleanupName(speciesLabel, 0)

	// Handle name collisions
	SetDataFolder root:XPSFit:Globals
	SVAR gSpectrumList
	if (WhichListItem(specName, gSpectrumList) >= 0)
		Variable sfx = 1
		do
			String testName = specName + "_" + num2str(sfx)
			if (WhichListItem(testName, gSpectrumList) < 0)
				specName = testName
				break
			endif
			sfx += 1
		while (sfx < 100)
	endif

	SetDataFolder root:XPSFit:Data
	String beName = "BE_" + specName
	String intName = "Int_" + specName
	Make/O/D/N=(nDataPts) $beName, $intName
	WAVE wBE = $beName
	WAVE wInt = $intName

	// Fill BE from start + step
	Variable pt
	for (pt = 0; pt < nDataPts; pt += 1)
		wBE[pt] = xStart + pt * xStep
	endfor

	// Read intensity (first corresponding variable)
	for (pt = 0; pt < nDataPts; pt += 1)
		FReadLine refNum, oneLine
		wInt[pt] = str2num(XPS_Trim(oneLine))
	endfor

	// Skip additional corresponding variable columns
	Variable nExtra = nOrdValues - nDataPts
	for (i = 0; i < nExtra; i += 1)
		FReadLine refNum, oneLine
	endfor

	// Convert kinetic energy to binding energy if needed
	if (strsearch(xLabel, "inetic", 0, 2) >= 0 && sourceEnergy > 0)
		for (pt = 0; pt < nDataPts; pt += 1)
			wBE[pt] = sourceEnergy - wBE[pt]
		endfor
		Print "  Converted KE -> BE (hv = " + num2str(sourceEnergy) + " eV)"
	endif

	// Register spectrum
	SetDataFolder root:XPSFit:Globals
	SVAR gCurr = gCurrentSpectrum
	gSpectrumList = AddListItem(specName, gSpectrumList, ";", Inf)
	gCurr = specName
	NVAR gNumPeaks
	gNumPeaks = 0

	SetDataFolder savDF

	Print "  Block: \"" + speciesLabel + "\" -> " + specName + " (" + num2str(nDataPts) + " pts, " + num2str(nScans) + " scans)"
	XPS_DisplaySpectrum(specName)
End


// ─────────────────────────────────────────────────────────────────────────────
//  SECTION 5 — Data I/O: Igor Binary (.ibw)
// ─────────────────────────────────────────────────────────────────────────────

static Function XPS_LoadIBWDialog()
	XPS_EnsureInit()

	Variable refNum
	Open/D/R/F="Igor Binary (*.ibw):.ibw;All Files:.*;" refNum
	String filePath = S_fileName
	if (strlen(filePath) == 0)
		return -1
	endif

	String savDF = GetDataFolder(1)
	SetDataFolder root:XPSFit:Data

	LoadWave/H/O/Q filePath
	if (V_flag == 0)
		DoAlert 0, "Failed to load Igor binary file."
		SetDataFolder savDF
		return -1
	endif

	String loadedNames = S_waveNames
	Variable nLoaded = ItemsInList(loadedNames)
	if (nLoaded == 0)
		DoAlert 0, "No waves found in file."
		SetDataFolder savDF
		return -1
	endif

	// Derive spectrum name from filename
	String fName = ParseFilePath(3, filePath, ":", 0, 0)
	Variable dotPos = strsearch(fName, ".", Inf, 1)
	if (dotPos > 0)
		fName = fName[0, dotPos - 1]
	endif
	String specName = CleanupName(fName, 0)

	Variable nPts
	String beName = "BE_" + specName
	String intName = "Int_" + specName

	if (nLoaded == 1)
		// Single wave: intensity with x-scaling as the BE axis
		String wName = StringFromList(0, loadedNames)
		WAVE wLoaded = $wName
		nPts = numpnts(wLoaded)

		Make/O/D/N=(nPts) $beName
		WAVE wBE = $beName
		Variable pt
		for (pt = 0; pt < nPts; pt += 1)
			wBE[pt] = pnt2x(wLoaded, pt)
		endfor

		Duplicate/O wLoaded, $intName
		if (CmpStr(wName, intName) != 0)
			KillWaves/Z $wName
		endif
	elseif (nLoaded >= 2)
		// Two waves: first = energy axis, second = intensity
		String w0Name = StringFromList(0, loadedNames)
		String w1Name = StringFromList(1, loadedNames)
		Duplicate/O $w0Name, $beName
		Duplicate/O $w1Name, $intName
		KillWaves/Z $w0Name, $w1Name
		// Kill any extras
		Variable k
		for (k = 2; k < nLoaded; k += 1)
			KillWaves/Z $StringFromList(k, loadedNames)
		endfor
		nPts = numpnts($beName)
	endif

	// Register
	SetDataFolder root:XPSFit:Globals
	SVAR gSpectrumList
	SVAR gCurrentSpectrum
	if (WhichListItem(specName, gSpectrumList) < 0)
		gSpectrumList = AddListItem(specName, gSpectrumList, ";", Inf)
	endif
	gCurrentSpectrum = specName
	NVAR gNumPeaks
	gNumPeaks = 0

	SetDataFolder savDF
	XPS_DisplaySpectrum(specName)
	Print "XPS Fitting: Loaded IBW -> \"" + specName + "\" (" + num2str(nPts) + " pts)"
End


// ─────────────────────────────────────────────────────────────────────────────
//  SECTION 6 — Remove Spectrum
// ─────────────────────────────────────────────────────────────────────────────

static Function XPS_RemoveSpectrum()
	XPS_EnsureInit()
	String savDF = GetDataFolder(1)

	SetDataFolder root:XPSFit:Globals
	SVAR gCurrentSpectrum
	SVAR gSpectrumList

	if (strlen(gCurrentSpectrum) == 0)
		DoAlert 0, "No spectrum loaded."
		SetDataFolder savDF
		return -1
	endif

	String specName = gCurrentSpectrum

	// Kill data
	SetDataFolder root:XPSFit:Data
	KillWaves/Z $("BE_" + specName), $("Int_" + specName)

	// Kill background
	SetDataFolder root:XPSFit:Backgrounds
	KillWaves/Z $("BG_" + specName)

	// Kill peak waves
	SetDataFolder root:XPSFit:Peaks
	String wList = WaveList("*" + specName + "*", ";", "")
	Variable nWaves = ItemsInList(wList)
	Variable i
	for (i = 0; i < nWaves; i += 1)
		KillWaves/Z $StringFromList(i, wList)
	endfor

	// Kill fit envelope
	SetDataFolder root:XPSFit:Fits
	KillWaves/Z $("Env_" + specName), $("EnvD_" + specName)

	// Kill graph
	DoWindow/K $("XPS_" + specName)

	// Update globals
	SetDataFolder root:XPSFit:Globals
	gSpectrumList = RemoveFromList(specName, gSpectrumList)
	if (ItemsInList(gSpectrumList) > 0)
		gCurrentSpectrum = StringFromList(0, gSpectrumList)
	else
		gCurrentSpectrum = ""
	endif
	NVAR gNumPeaks
	gNumPeaks = 0

	SetDataFolder savDF
	Print "XPS Fitting: Removed \"" + specName + "\""
End


// ─────────────────────────────────────────────────────────────────────────────
//  SECTION 7 — Graph Display (Module 1: raw spectrum only)
// ─────────────────────────────────────────────────────────────────────────────

static Function XPS_DisplaySpectrum(specName)
	String specName

	WAVE wBE = root:XPSFit:Data:$("BE_" + specName)
	WAVE wInt = root:XPSFit:Data:$("Int_" + specName)

	String graphName = "XPS_" + specName
	DoWindow/K $graphName

	Display/K=1/W=(50,50,50+kGraphWidth,50+kGraphHeight)/N=$graphName wInt vs wBE
	ModifyGraph/W=$graphName mode=0, lsize=1
	ModifyGraph/W=$graphName rgb=(0,0,0)
	ModifyGraph/W=$graphName mirror=2, standoff=0
	ModifyGraph/W=$graphName tick=2, btLen=4
	Label/W=$graphName bottom "Binding Energy (eV)"
	Label/W=$graphName left "Intensity (counts)"
	SetAxis/A/R/W=$graphName bottom
	ModifyGraph/W=$graphName font="Arial", fSize=11

	// Cursor A at midpoint for peak placement
	Cursor/W=$graphName A, $NameOfWave(wInt), floor(numpnts(wBE) / 2)
End


// ─────────────────────────────────────────────────────────────────────────────
//  SECTION 8 — Utility: Trim line endings
// ─────────────────────────────────────────────────────────────────────────────

static Function/S XPS_Trim(inStr)
	String inStr
	Variable len = strlen(inStr)
	do
		if (len <= 0)
			break
		endif
		String ch = inStr[len - 1]
		if (CmpStr(ch, "\r") == 0 || CmpStr(ch, "\n") == 0 || CmpStr(ch, " ") == 0 || CmpStr(ch, "\t") == 0)
			len -= 1
		else
			break
		endif
	while(1)
	if (len <= 0)
		return ""
	endif
	return inStr[0, len - 1]
End


// ─────────────────────────────────────────────────────────────────────────────
//  SECTION 9 — Stubs (so the menu compiles before later modules)
// ─────────────────────────────────────────────────────────────────────────────

static Function XPS_OpenPanel()
	XPS_EnsureInit()
	DoAlert 0, "Panel (Module 8) not yet built. Use the XPS Fitting menu."
End

static Function XPS_ComputeBackground(bgType)
	String bgType
	Print "XPS Fitting: Background module not yet built."
End

static Function XPS_ClearBackground()
	Print "XPS Fitting: Background module not yet built."
End

static Function XPS_AddPeakAtCursor()
	Print "XPS Fitting: Peak module not yet built."
End

static Function XPS_RemoveLastPeak()
	Print "XPS Fitting: Peak module not yet built."
End

static Function XPS_ClearAllPeaks()
	Print "XPS Fitting: Peak module not yet built."
End

static Function XPS_RunFit()
	Print "XPS Fitting: Fit module not yet built."
End

static Function XPS_UpdatePanelControls()
	// Placeholder
End

static Function XPS_About()
	DoAlert 0, "XPS Fitting Package v1.0\r\rGeneral-purpose XPS peak fitting\rfor Igor Pro 9\r\rW. DeBenedetti, 2026"
End
