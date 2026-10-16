// Country -> government identity number requirements for STRICT seller onboarding.
// Sellers ONLY (buyers need just a normal account). v1: manual review of the
// uploaded ID document + number format check. Format validation is syntactic;
// real registry verification is a future partnership step.
export interface CountryIdSpec {
  country: string;      // ISO 3166-1 alpha-2
  name: string;
  idName: string;       // e.g. "Social Security Number"
  idKey: string;        // e.g. "ssn"
  pattern: RegExp;      // syntactic format check
  example: string;
  hint: string;
}

export const COUNTRY_ID_MAP: Record<string, CountryIdSpec> = {
  US: {
    country: 'US', name: 'United States', idName: 'Social Security Number', idKey: 'ssn',
    pattern: /^\d{3}-?\d{2}-?\d{4}$/, example: '123-45-6789',
    hint: '9-digit SSN (dashes optional).',
  },
  NG: {
    country: 'NG', name: 'Nigeria', idName: 'National Identification Number', idKey: 'nin',
    pattern: /^\d{11}$/, example: '12345678901',
    hint: '11-digit NIN from NIMC.',
  },
  GB: {
    country: 'GB', name: 'United Kingdom', idName: 'National Insurance number', idKey: 'nino',
    pattern: /^[A-CEGHJ-PR-TW-Z]{2}\d{6}[A-D]$/i, example: 'AB123456C',
    hint: '2 letters, 6 digits, 1 letter (e.g. AB123456C).',
  },
  CA: {
    country: 'CA', name: 'Canada', idName: 'Social Insurance Number', idKey: 'sin',
    pattern: /^\d{3}-?\d{3}-?\d{3}$/, example: '123-456-789',
    hint: '9-digit SIN (dashes optional).',
  },
  IN: {
    country: 'IN', name: 'India', idName: 'Aadhaar number', idKey: 'aadhaar',
    pattern: /^\d{4}-?\d{4}-?\d{4}$/, example: '1234-5678-9012',
    hint: '12-digit Aadhaar (spaces/dashes optional).',
  },
  GH: {
    country: 'GH', name: 'Ghana', idName: 'Ghana Card number', idKey: 'ghana_card',
    pattern: /^GHA-?\d{9}-?\d$/i, example: 'GHA-123456789-0',
    hint: 'Ghana Card number (e.g. GHA-123456789-0).',
  },
  KE: {
    country: 'KE', name: 'Kenya', idName: 'National ID number', idKey: 'national_id',
    pattern: /^\d{7,8}$/, example: '12345678',
    hint: '7-8 digit national ID number.',
  },
  ZA: {
    country: 'ZA', name: 'South Africa', idName: 'ID number', idKey: 'sa_id',
    pattern: /^\d{13}$/, example: '8001015009087',
    hint: '13-digit SA ID number (YYMMDD SSSS 08 A).',
  },
};

// Default for countries not listed: government-issued photo ID number
// (passport, driver's license, or national ID). Manual review decides.
export const DEFAULT_ID_SPEC: CountryIdSpec = {
  country: 'XX', name: 'Other', idName: 'Government ID number', idKey: 'gov_id',
  pattern: /^[A-Z0-9-]{5,30}$/i, example: 'A1234567',
  hint: 'Passport, driver\'s license, or national ID number.',
};

export function idSpecFor(country: string): CountryIdSpec {
  const c = (country || '').toUpperCase();
  return COUNTRY_ID_MAP[c] ?? { ...DEFAULT_ID_SPEC, country: c || 'XX' };
}

export function validateIdNumber(country: string, idNumber: string): { ok: boolean; spec: CountryIdSpec } {
  const spec = idSpecFor(country);
  const v = (idNumber || '').trim();
  return { ok: spec.pattern.test(v), spec };
}
