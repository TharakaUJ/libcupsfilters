//
// Regression test for issue #166: cfFilterPWGToPDF() must fail the job
// cleanly when prepare_pdf_page() rejects a page.  It pulls in the real
// cupsfilters/pwgtopdf.c, writes a one-row 8-bit CIELab PWG Raster page (a
// color space prepare_pdf_page() does not support) and runs the filter on
// it.  Before the fix, add_pdf_page() ignored the failure and
// convert_raster() called the NULL doc->bit_function.
//
// Copyright © 2026 by OpenPrinting
//
// Licensed under Apache License v2.0.  See the file "LICENSE" for more
// information.
//

// Include the unit under test so it is built with AddressSanitizer even when
// the library itself is not.
#include "cupsfilters/pwgtopdf.c"


//
// 'write_page()' - Write a one-row CIELab PWG Raster page to a file.
//

static int				// O - 0 on success, 1 on failure
write_page(const char *filename)	// I - File to write
{
  cups_page_header_t	header;		// Page header
  unsigned char		row[384];	// One row of 128 Lab pixels
  cups_raster_t		*ras;		// Raster stream
  int			fd;		// File descriptor
  int			ret = 1;	// Return value


  if ((fd = open(filename, O_CREAT | O_TRUNC | O_WRONLY, 0644)) < 0)
    return (1);

  if ((ras = cupsRasterOpen(fd, CUPS_RASTER_WRITE)) == NULL)
  {
    close(fd);
    return (1);
  }

  memset(&header, 0, sizeof(header));
  header.HWResolution[0]    = header.HWResolution[1] = 300;
  header.PageSize[0]        = 612;
  header.PageSize[1]        = 792;
  header.cupsPageSize[0]    = 612.0f;
  header.cupsPageSize[1]    = 792.0f;
  header.cupsImagingBBox[2] = 612.0f;
  header.cupsImagingBBox[3] = 792.0f;
  header.cupsWidth          = 128;
  header.cupsHeight         = 1;
  header.cupsBitsPerColor   = 8;
  header.cupsBitsPerPixel   = 24;
  header.cupsNumColors      = 3;
  header.cupsBytesPerLine   = sizeof(row);
  header.cupsColorOrder     = CUPS_ORDER_CHUNKED;
  header.cupsColorSpace     = CUPS_CSPACE_CIELab;

  memset(row, 0, sizeof(row));

  if (cupsRasterWriteHeader(ras, &header) &&
      cupsRasterWritePixels(ras, row, sizeof(row)) == sizeof(row))
    ret = 0;

  cupsRasterClose(ras);
  close(fd);

  return (ret);
}


//
// 'main()' - Run pwgtopdf on the CIELab page.
//

int					// O - Filter exit status
main(int  argc,				// I - Number of command-line arguments
     char *argv[])			// I - Command-line arguments
{
  cf_filter_data_t	data;		// Filter data
  cf_filter_out_format_t outformat = CF_FILTER_OUT_FORMAT_PDF;
					// Output format
  int			inputfd,	// Input file
			outputfd,	// Output file
			result;		// Filter result


  if (argc != 3)
  {
    fprintf(stderr, "Usage: %s INPUT.pwg OUTPUT.pdf\n", argv[0]);
    return (2);
  }

  if (write_page(argv[1]))
  {
    fprintf(stderr, "Unable to write %s\n", argv[1]);
    return (2);
  }

  inputfd  = open(argv[1], O_RDONLY);
  outputfd = open(argv[2], O_CREAT | O_TRUNC | O_WRONLY, 0644);
  if (inputfd < 0 || outputfd < 0)
  {
    perror("open");
    return (2);
  }

  memset(&data, 0, sizeof(data));
  data.content_type       = (char *)"image/pwg-raster";
  data.final_content_type = (char *)"application/pdf";
  data.logfunc            = cfCUPSLogFunc;

  result = cfFilterPWGToPDF(inputfd, outputfd, 1, &data, &outformat);

  close(inputfd);
  close(outputfd);

  return (result);
}
